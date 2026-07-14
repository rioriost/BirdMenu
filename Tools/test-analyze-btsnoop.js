#!/usr/bin/env node

const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const repoRoot = path.resolve(__dirname, "..");
const samplePath = path.join(os.tmpdir(), `birdmenu-btsnoop-${process.pid}.log`);
const appleSamplePath = path.join(os.tmpdir(), `birdmenu-packetlogger-${process.pid}.pklg`);

fs.writeFileSync(samplePath, makeBtsnoop([
  makeACLATT(0x000b, Buffer.from([0x08, 0x01, 0x00, 0xff, 0xff, 0x03, 0x28])),
  makeACLATT(0x000b, Buffer.from([
    0x09, 0x07,
    0x24, 0x00, 0x1a, 0x25, 0x00, 0xf5, 0xff,
    0x26, 0x00, 0x10, 0x27, 0x00, 0xf6, 0xff
  ])),
  makeACLATT(0x000b, Buffer.from([0x05, 0x01, 0x28, 0x00, 0x02, 0x29])),
  makeACLATT(0x000b, Buffer.from([0x12, 0x28, 0x00, 0x01, 0x00])),
  makeACLATT(0x000b, Buffer.from([0x12, 0x25, 0x00, 0x02])),
  makeACLATT(0x000b, Buffer.from([0x13])),
  makeACLATT(0x000b, Buffer.from([0x1b, 0x27, 0x00, 0x72, 0x74, 0x64, 0x74, 0x68, 0xfe, 0x00, 0x55, 0x02]))
]));

try {
  const json = execFileSync("node", [
    path.join(repoRoot, "Tools", "analyze-btsnoop.js"),
    "--json",
    samplePath
  ], { encoding: "utf8" });
  const parsed = JSON.parse(json);
  assert.equal(parsed.events.some((event) => event.kind === "write_request" && event.valueHex === "02" && event.uuid === "FFF5"), true);
  assert.equal(parsed.events.some((event) => event.kind === "write_request" && event.note === "cccd=notify_on"), true);
  assert.equal(parsed.events.some((event) => event.kind === "notification" && event.uuid === "FFF6" && event.valueHex.startsWith("7274647468")), true);
  assert.equal(parsed.writeSummary.length, 2);
  assert.equal(parsed.writeSummary.some((item) => item.followups.some((followup) => followup.event.kind === "notification")), true);
  assert.equal(parsed.candidateCommandPlan.length, 1);
  assert.equal(parsed.candidateCommandPlan[0].uuid, "FFF5");
  assert.equal(parsed.candidateCommandPlan[0].responseTargets.includes("FFF6"), true);

  const plan = execFileSync("node", [
    path.join(repoRoot, "Tools", "analyze-btsnoop.js"),
    "--plan",
    samplePath
  ], { encoding: "utf8" });
  assert.match(plan, /write_with_response FFF5 value=02/);
} finally {
  fs.rmSync(samplePath, { force: true });
}

fs.writeFileSync(appleSamplePath, makeApplePacketLogger([
  appleRecord(0xfc, Buffer.from("Product: iPhone17,1", "utf8")),
  appleRecord(0x01, Buffer.from([
    0x3e, 0x2a, 0x0d, 0x01,
    0x10, 0x00,
    0x01,
    0x01, 0x02, 0x03, 0x04, 0x05, 0x06,
    0x01, 0x00, 0xff, 0xc0, 0xd0, 0x00, 0x00, 0x00,
    0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x11,
    0x02, 0x01, 0x06,
    0x03, 0x03, 0xf0, 0xff,
    0x09, 0x09, 0x49, 0x54, 0x48, 0x2d, 0x31, 0x31, 0x2d, 0x42
  ]))
]));

try {
  const json = execFileSync("node", [
    path.join(repoRoot, "Tools", "analyze-btsnoop.js"),
    "--json",
    appleSamplePath
  ], { encoding: "utf8" });
  const parsed = JSON.parse(json);
  assert.equal(parsed.format, "apple-packetlogger");
  assert.equal(parsed.timestampBasis, "device-local-wall-clock");
  assert.equal(parsed.metadata.includes("Product: iPhone17,1"), true);
  assert.equal(parsed.advertisingReports.some((report) => report.name === "ITH-11-B"), true);
  assert.equal(parsed.advertisingReports[0].timestamp, "1970-01-01T00:00:01.000Z");
} finally {
  fs.rmSync(appleSamplePath, { force: true });
}

function makeBtsnoop(hciPackets) {
  const header = Buffer.alloc(16);
  header.write("btsnoop\u0000", 0, "binary");
  header.writeUInt32BE(1, 8);
  header.writeUInt32BE(1002, 12);

  const records = [];
  let timestamp = 0x00dcddb30f2f8000n + 1_700_000_000_000_000n;
  for (const packet of hciPackets) {
    const recordHeader = Buffer.alloc(24);
    recordHeader.writeUInt32BE(packet.length, 0);
    recordHeader.writeUInt32BE(packet.length, 4);
    recordHeader.writeUInt32BE(1, 8);
    recordHeader.writeUInt32BE(0, 12);
    recordHeader.writeBigUInt64BE(timestamp, 16);
    records.push(recordHeader, packet);
    timestamp += 100_000n;
  }
  return Buffer.concat([header, ...records]);
}

function makeACLATT(connectionHandle, attPayload) {
  const l2capLength = attPayload.length;
  const hciLength = l2capLength + 4;
  const packet = Buffer.alloc(1 + 4 + 4 + attPayload.length);
  packet[0] = 0x02;
  packet.writeUInt16LE(connectionHandle, 1);
  packet.writeUInt16LE(hciLength, 3);
  packet.writeUInt16LE(l2capLength, 5);
  packet.writeUInt16LE(0x0004, 7);
  attPayload.copy(packet, 9);
  return packet;
}

function makeApplePacketLogger(records) {
  return Buffer.concat(records);
}

function appleRecord(type, payload) {
  const recordLength = 8 + 1 + payload.length;
  const record = Buffer.alloc(4 + recordLength);
  record.writeUInt32LE(recordLength, 0);
  record.writeUInt32LE(1, 4);
  record.writeUInt32LE(0, 8);
  record[12] = type;
  payload.copy(record, 13);
  return record;
}

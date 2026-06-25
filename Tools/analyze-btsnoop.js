#!/usr/bin/env node

const fs = require("fs");

const ATT_CID = 0x0004;
const BTSNOOP_EPOCH_DELTA_US = 0x00dcddb30f2f8000n;

function usage() {
  console.error("Usage: node Tools/analyze-btsnoop.js [--json] [--summary] [--plan] [--all] <btsnoop_hci.log>");
  process.exit(2);
}

const args = process.argv.slice(2);
const options = {
  json: false,
  summary: false,
  plan: false,
  all: false
};
const files = [];
for (const arg of args) {
  if (arg === "--json") {
    options.json = true;
  } else if (arg === "--summary") {
    options.summary = true;
  } else if (arg === "--plan") {
    options.plan = true;
  } else if (arg === "--all") {
    options.all = true;
  } else {
    files.push(arg);
  }
}

const path = files[0];
if (!path) {
  usage();
}

const data = fs.readFileSync(path);
if (data.length < 16 || data.subarray(0, 8).toString("binary") !== "btsnoop\u0000") {
  const appleCapture = parseApplePacketLogger(data);
  if (!appleCapture) {
    throw new Error("Not a btsnoop or Apple PacketLogger file.");
  }
  printApplePacketLogger(appleCapture);
  process.exit(0);
}

let offset = 16;
let packetIndex = 0;
const rows = [];
const handleMap = new Map();
const descriptorMap = new Map();
const pendingReadByType = new Map();
const pendingFindInfo = new Map();
const pendingRead = new Map();

while (offset + 24 <= data.length) {
  const originalLength = data.readUInt32BE(offset);
  const includedLength = data.readUInt32BE(offset + 4);
  const flags = data.readUInt32BE(offset + 8);
  const timestampRaw = data.readBigUInt64BE(offset + 16);
  offset += 24;

  if (offset + includedLength > data.length) {
    break;
  }
  const packet = data.subarray(offset, offset + includedLength);
  offset += includedLength;
  packetIndex += 1;

  const timestamp = btsnoopDate(timestampRaw);
  const direction = flags & 0x01 ? "rx" : "tx";
  const acl = parseACL(packet);
  if (!acl || acl.cid !== ATT_CID) {
    continue;
  }

  const att = acl.payload;
  if (att.length === 0) {
    continue;
  }
  const opcode = att[0];
  const event = parseATT(opcode, att, direction, acl.handle, timestamp, pendingReadByType.get(acl.handle));
  if (!event) {
    continue;
  }

  if (event.kind === "read_by_type_request") {
    pendingReadByType.set(acl.handle, event.uuid);
  } else if (event.kind === "read_by_type_response") {
    const uuid = pendingReadByType.get(acl.handle);
    if (uuid) {
      if (uuid === "2803") {
        for (const characteristic of event.characteristics) {
          handleMap.set(characteristic.valueHandle, characteristic.uuid);
        }
      } else {
        for (const handle of event.handles) {
          handleMap.set(handle, uuid);
        }
      }
    }
  } else if (event.kind === "find_info_request") {
    pendingFindInfo.set(acl.handle, true);
  } else if (event.kind === "find_info_response") {
    for (const entry of event.entries) {
      if (entry.uuid === "2902") {
        descriptorMap.set(entry.handle, entry.uuid);
      } else {
        handleMap.set(entry.handle, entry.uuid);
      }
    }
  } else if (event.kind === "read_request") {
    pendingRead.set(acl.handle, event.attributeHandle);
  } else if (event.kind === "read_response") {
    const attributeHandle = pendingRead.get(acl.handle);
    if (attributeHandle) {
      event.attributeHandle = attributeHandle;
    }
  }

  rows.push({
    packetIndex,
    timestamp,
    direction,
    connectionHandle: acl.handle,
    ...event
  });
}

applyHandleMetadata(rows, handleMap, descriptorMap);

const selectedRows = options.all ? rows : rows.filter(shouldPrint);
if (options.json) {
  const writeSummary = summarizeWrites(rows);
  process.stdout.write(JSON.stringify({
    source: path,
    events: selectedRows.map(jsonRow),
    writeSummary: writeSummary.map(jsonSummary),
    candidateCommandPlan: buildCommandPlan(writeSummary)
  }, null, 2));
  process.stdout.write("\n");
} else if (options.plan) {
  printPlan(buildCommandPlan(summarizeWrites(rows)));
} else if (options.summary) {
  printSummary(summarizeWrites(rows));
} else {
  for (const row of selectedRows) {
    console.log(formatRow(row));
  }
}

function btsnoopDate(timestampRaw) {
  const unixUs = timestampRaw - BTSNOOP_EPOCH_DELTA_US;
  return new Date(Number(unixUs / 1000n));
}

function parseApplePacketLogger(buffer) {
  let offset = 0;
  let recordIndex = 0;
  const rows = [];
  const metadata = [];
  const hciCommands = [];
  const advertisingReports = [];
  const handleMap = new Map();
  const descriptorMap = new Map();
  const pendingReadByType = new Map();
  const pendingRead = new Map();

  while (offset + 13 <= buffer.length) {
    const recordLength = buffer.readUInt32LE(offset);
    if (recordLength < 9 || offset + 4 + recordLength > buffer.length) {
      return recordIndex > 0 ? { format: "apple-packetlogger", metadata, hciCommands, advertisingReports, rows } : null;
    }
    const packetTimestamp = new Date(recordIndex);
    const packetType = buffer[offset + 12];
    const payload = buffer.subarray(offset + 13, offset + 4 + recordLength);
    offset += 4 + recordLength;
    recordIndex += 1;

    if (packetType === 0xfc) {
      metadata.push(payload.toString("utf8"));
      continue;
    }
    if (packetType === 0xfd) {
      metadata.push(`Selected Device: ${formatSelectedDevice(payload)}`);
      continue;
    }
    if (packetType === 0x00) {
      const command = parseHCICommand(payload, packetTimestamp);
      if (command) hciCommands.push(command);
      continue;
    }
    if (packetType === 0x01) {
      advertisingReports.push(...parseHCIEvent(payload, packetTimestamp));
      continue;
    }
    if (packetType !== 0x02 && packetType !== 0x03) {
      continue;
    }

    const direction = packetType === 0x02 ? "tx" : "rx";
    const acl = parseACL(payload);
    if (!acl || acl.cid !== ATT_CID || acl.payload.length === 0) {
      continue;
    }

    const event = parseATT(
      acl.payload[0],
      acl.payload,
      direction,
      acl.handle,
      packetTimestamp,
      pendingReadByType.get(acl.handle)
    );
    if (!event) {
      continue;
    }
    updateATTState(event, acl.handle, handleMap, descriptorMap, pendingReadByType, pendingRead);
    rows.push({
      packetIndex: recordIndex,
      timestamp: packetTimestamp,
      direction,
      connectionHandle: acl.handle,
      ...event
    });
  }

  applyHandleMetadata(rows, handleMap, descriptorMap);

  return { format: "apple-packetlogger", metadata, hciCommands, advertisingReports, rows };
}

function applyHandleMetadata(rows, handleMap, descriptorMap) {
  inferITH11BHandles(rows, handleMap, descriptorMap);
  for (const row of rows) {
    if (row.attributeHandle && !row.uuid) {
      row.uuid = handleMap.get(row.attributeHandle) ?? descriptorMap.get(row.attributeHandle);
    }
    if (row.attributeHandle && descriptorMap.get(row.attributeHandle) === "2902") {
      row.note = cccdNote(row.valueHex);
    }
  }
}

function inferITH11BHandles(rows, handleMap, descriptorMap) {
  const hasFFF3 = Array.from(handleMap.values()).includes("FFF3");
  const hasFFF4 = Array.from(handleMap.values()).includes("FFF4");
  const hasFFF5 = Array.from(handleMap.values()).includes("FFF5");
  if (!hasFFF3 || !hasFFF4 || !hasFFF5) {
    return;
  }
  for (const [handle, uuid] of descriptorMap.entries()) {
    if (uuid === "2902" && !handleMap.has(handle - 1)) {
      handleMap.set(handle - 1, "FFF6");
    }
  }
  for (const row of rows) {
    if ((row.kind === "write_command" || row.kind === "write_request") && row.attributeHandle && !handleMap.has(row.attributeHandle)) {
      handleMap.set(row.attributeHandle, "FFF7");
    }
  }
}

function updateATTState(event, connectionHandle, handleMap, descriptorMap, pendingReadByType, pendingRead) {
  if (event.kind === "read_by_type_request") {
    pendingReadByType.set(connectionHandle, event.uuid);
  } else if (event.kind === "read_by_type_response") {
    const uuid = pendingReadByType.get(connectionHandle);
    if (!uuid) return;
    if (uuid === "2803") {
      for (const characteristic of event.characteristics) {
        handleMap.set(characteristic.valueHandle, characteristic.uuid);
      }
    } else {
      for (const handle of event.handles) {
        handleMap.set(handle, uuid);
      }
    }
  } else if (event.kind === "find_info_response") {
    for (const entry of event.entries) {
      if (entry.uuid === "2902") {
        descriptorMap.set(entry.handle, entry.uuid);
      } else {
        handleMap.set(entry.handle, entry.uuid);
      }
    }
  } else if (event.kind === "read_request") {
    pendingRead.set(connectionHandle, event.attributeHandle);
  } else if (event.kind === "read_response") {
    const attributeHandle = pendingRead.get(connectionHandle);
    if (attributeHandle) {
      event.attributeHandle = attributeHandle;
    }
  }
}

function printApplePacketLogger(capture) {
  const selectedRows = options.all ? capture.rows : capture.rows.filter(shouldPrint);
  const writeSummary = summarizeWrites(capture.rows);
  const commandPlan = buildCommandPlan(writeSummary);
  const interestingAdvertisements = capture.advertisingReports.filter(isInterestingAdvertisement);

  if (options.json) {
    process.stdout.write(JSON.stringify({
      source: path,
      format: capture.format,
      metadata: capture.metadata,
      hciCommands: capture.hciCommands,
      advertisingReports: interestingAdvertisements,
      events: selectedRows.map(jsonRow),
      writeSummary: writeSummary.map(jsonSummary),
      candidateCommandPlan: commandPlan
    }, null, 2));
    process.stdout.write("\n");
    return;
  }

  console.log("Apple PacketLogger capture");
  for (const item of capture.metadata) {
    console.log(`metadata: ${item}`);
  }
  console.log(`hciCommands=${capture.hciCommands.length} advertisements=${capture.advertisingReports.length} attEvents=${capture.rows.length}`);
  if (interestingAdvertisements.length > 0) {
    console.log("");
    console.log("Interesting advertisements:");
    for (const report of interestingAdvertisements.slice(0, 40)) {
      console.log(`${report.address} name=${report.name || "-"} uuids=${report.serviceUUIDs.join(",") || "-"} mfr=${report.manufacturerDataHex || "-"}`);
    }
  }
  if (capture.rows.length === 0) {
    console.log("");
    console.log("No ATT traffic was found. This capture does not contain BLE connection writes/notifications.");
    return;
  }
  if (options.plan) {
    printPlan(commandPlan);
  } else if (options.summary) {
    printSummary(writeSummary);
  } else {
    for (const row of selectedRows) {
      console.log(formatRow(row));
    }
  }
}

function parseHCICommand(payload, timestamp) {
  if (payload.length < 3) return null;
  return {
    timestamp: timestamp.toISOString(),
    opcode: `0x${payload.readUInt16LE(0).toString(16).padStart(4, "0")}`,
    parameterLength: payload[2],
    valueHex: hex(payload.subarray(3))
  };
}

function parseHCIEvent(payload, timestamp) {
  if (payload.length < 3 || payload[0] !== 0x3e || payload[2] !== 0x0d) {
    return [];
  }
  const reports = [];
  const reportCount = payload[3] ?? 0;
  let offset = 4;
  for (let index = 0; index < reportCount && offset + 24 <= payload.length; index += 1) {
    const eventType = payload.readUInt16LE(offset);
    const addressType = payload[offset + 2];
    const address = bluetoothAddress(payload.subarray(offset + 3, offset + 9));
    const dataLength = payload[offset + 23];
    const data = payload.subarray(offset + 24, offset + 24 + dataLength);
    const fields = parseAdvertisingData(data);
    reports.push({
      timestamp: timestamp.toISOString(),
      eventType: `0x${eventType.toString(16).padStart(4, "0")}`,
      addressType,
      address,
      name: fields.name,
      serviceUUIDs: fields.serviceUUIDs,
      manufacturerDataHex: fields.manufacturerDataHex,
      dataHex: hex(data)
    });
    offset += 24 + dataLength;
  }
  return reports;
}

function parseAdvertisingData(data) {
  const serviceUUIDs = [];
  let name = "";
  let manufacturerDataHex = "";
  for (let offset = 0; offset < data.length;) {
    const length = data[offset];
    if (length === 0 || offset + 1 + length > data.length) {
      break;
    }
    const type = data[offset + 1];
    const value = data.subarray(offset + 2, offset + 1 + length);
    if (type === 0x08 || type === 0x09) {
      name = value.toString("utf8").replace(/\0+$/, "");
    } else if (type === 0xff) {
      manufacturerDataHex = hex(value);
    } else if (type === 0x02 || type === 0x03) {
      for (let index = 0; index + 1 < value.length; index += 2) {
        serviceUUIDs.push(value.readUInt16LE(index).toString(16).padStart(4, "0").toUpperCase());
      }
    } else if (type === 0x06 || type === 0x07) {
      for (let index = 0; index + 15 < value.length; index += 16) {
        serviceUUIDs.push(formatUUID(value.subarray(index, index + 16)));
      }
    }
    offset += 1 + length;
  }
  return { name, serviceUUIDs, manufacturerDataHex };
}

function isInterestingAdvertisement(report) {
  if (/ITH-11-B|INKBIRD/i.test(report.name)) return true;
  if (report.serviceUUIDs.some((uuid) => /FFF0|5833/i.test(uuid))) return true;
  if (/4924|2449|7274647468/i.test(report.manufacturerDataHex)) return true;
  return false;
}

function formatSelectedDevice(payload) {
  const text = payload.toString("utf8").replace(/\0/g, " ").trim();
  return `${text || "-"} hex=${hex(payload)}`;
}

function parseACL(packet) {
  let start = 0;
  if (packet[0] === 0x02) {
    start = 1;
  }
  if (packet.length < start + 8) {
    return null;
  }
  const handleFlags = packet.readUInt16LE(start);
  const handle = handleFlags & 0x0fff;
  const hciLength = packet.readUInt16LE(start + 2);
  if (packet.length < start + 4 + hciLength || hciLength < 4) {
    return null;
  }
  const l2capLength = packet.readUInt16LE(start + 4);
  const cid = packet.readUInt16LE(start + 6);
  const payloadStart = start + 8;
  const payloadEnd = Math.min(payloadStart + l2capLength, packet.length);
  return {
    handle,
    cid,
    payload: packet.subarray(payloadStart, payloadEnd)
  };
}

function parseATT(
  opcode,
  att,
  direction,
  connectionHandle,
  timestamp,
  requestedReadByTypeUUID
) {
  const readByTypeUUID = requestedReadByTypeUUID;
  switch (opcode) {
  case 0x04:
    if (att.length < 5) return null;
    return {
      kind: "find_info_request",
      startHandle: att.readUInt16LE(1),
      endHandle: att.readUInt16LE(3)
    };
  case 0x05:
    return parseFindInfoResponse(att);
  case 0x08:
    if (att.length < 7) return null;
    return {
      kind: "read_by_type_request",
      startHandle: att.readUInt16LE(1),
      endHandle: att.readUInt16LE(3),
      uuid: formatUUID(att.subarray(5))
    };
  case 0x09:
    return parseReadByTypeResponse(att, readByTypeUUID);
  case 0x0a:
    if (att.length < 3) return null;
    return {
      kind: "read_request",
      attributeHandle: att.readUInt16LE(1)
    };
  case 0x0b:
    return {
      kind: "read_response",
      valueHex: hex(att.subarray(1))
    };
  case 0x12:
    if (att.length < 3) return null;
    return {
      kind: "write_request",
      attributeHandle: att.readUInt16LE(1),
      valueHex: hex(att.subarray(3))
    };
  case 0x13:
    return { kind: "write_response" };
  case 0x1b:
    if (att.length < 3) return null;
    return {
      kind: "notification",
      attributeHandle: att.readUInt16LE(1),
      valueHex: hex(att.subarray(3))
    };
  case 0x1d:
    if (att.length < 3) return null;
    return {
      kind: "indication",
      attributeHandle: att.readUInt16LE(1),
      valueHex: hex(att.subarray(3))
    };
  case 0x52:
    if (att.length < 3) return null;
    return {
      kind: "write_command",
      attributeHandle: att.readUInt16LE(1),
      valueHex: hex(att.subarray(3))
    };
  default:
    return {
      kind: `att_0x${opcode.toString(16).padStart(2, "0")}`,
      valueHex: hex(att.subarray(1))
    };
  }
}

function parseFindInfoResponse(att) {
  if (att.length < 2) return null;
  const format = att[1];
  const entryLength = format === 0x01 ? 4 : 18;
  const entries = [];
  for (let i = 2; i + entryLength <= att.length; i += entryLength) {
    const handle = att.readUInt16LE(i);
    const uuidBytes = att.subarray(i + 2, i + entryLength);
    entries.push({ handle, uuid: formatUUID(uuidBytes) });
  }
  return { kind: "find_info_response", entries };
}

function parseReadByTypeResponse(att, requestedUUID) {
  if (att.length < 2) return null;
  const entryLength = att[1];
  const handles = [];
  const characteristics = [];
  for (let i = 2; entryLength > 0 && i + entryLength <= att.length; i += entryLength) {
    const handle = att.readUInt16LE(i);
    handles.push(handle);
    if (requestedUUID === "2803" && entryLength >= 7) {
      const uuidStart = i + 5;
      const uuidEnd = i + entryLength;
      characteristics.push({
        declarationHandle: handle,
        properties: att[i + 2],
        valueHandle: att.readUInt16LE(i + 3),
        uuid: formatUUID(att.subarray(uuidStart, uuidEnd))
      });
    }
  }
  return { kind: "read_by_type_response", handles, characteristics, valueHex: hex(att.subarray(2)) };
}

function shouldPrint(row) {
  if (row.note) {
    return true;
  }
  if (row.kind.includes("write") || row.kind === "notification" || row.kind === "indication") {
    return true;
  }
  if (row.uuid && /fff|5833/i.test(row.uuid)) {
    return true;
  }
  if (row.valueHex && /(fff|5833|7274647468)/i.test(row.valueHex)) {
    return true;
  }
  return false;
}

function summarizeWrites(allRows) {
  const writes = [];
  for (let index = 0; index < allRows.length; index += 1) {
    const row = allRows[index];
    if (row.kind !== "write_request" && row.kind !== "write_command") {
      continue;
    }
    const followups = [];
    const writeTime = row.timestamp.getTime();
    for (let next = index + 1; next < allRows.length; next += 1) {
      const nextRow = allRows[next];
      const elapsedMs = nextRow.timestamp.getTime() - writeTime;
      if (elapsedMs > 5000) {
        break;
      }
      if (nextRow.connectionHandle !== row.connectionHandle) {
        continue;
      }
      if (nextRow.kind === "notification" || nextRow.kind === "indication" || nextRow.kind === "read_response") {
        followups.push({ elapsedMs, row: nextRow });
      }
    }
    writes.push({ write: row, followups });
  }
  return writes;
}

function cccdNote(valueHex) {
  if (!valueHex) {
    return undefined;
  }
  if (valueHex === "0100") {
    return "cccd=notify_on";
  }
  if (valueHex === "0200") {
    return "cccd=indicate_on";
  }
  if (valueHex === "0000") {
    return "cccd=notify_indicate_off";
  }
  return undefined;
}

function printSummary(summaryRows) {
  const candidates = [];
  for (const item of summaryRows) {
    console.log(formatRow(item.write));
    if (item.followups.length === 0) {
      console.log("  -> no notify/read response within 5s");
      continue;
    }
    for (const followup of item.followups) {
      console.log(`  +${followup.elapsedMs}ms ${formatRow(followup.row)}`);
    }
    if (isInterestingWrite(item.write)) {
      candidates.push(item);
    }
  }

  if (candidates.length > 0) {
    console.log("");
    console.log("Candidate history-sync writes:");
    for (const item of candidates) {
      const write = item.write;
      const responses = item.followups
        .filter((followup) => followup.row.kind === "notification" || followup.row.kind === "indication")
        .map((followup) => `${followup.row.uuid ?? `handle=0x${followup.row.attributeHandle?.toString(16)}`}:${followup.row.valueHex?.slice(0, 24) ?? ""}`);
      console.log(`- ${write.uuid ?? `handle=0x${write.attributeHandle?.toString(16)}`} value=${write.valueHex ?? ""} responses=${responses.join(",") || "-"}`);
    }
  }
}

function buildCommandPlan(summaryRows) {
  return summaryRows
    .filter((item) => isPlanWrite(item))
    .map((item) => {
      const write = item.write;
      const responses = item.followups
        .filter((followup) => followup.row.kind === "notification" || followup.row.kind === "indication" || followup.row.kind === "read_response")
        .map((followup) => ({
          elapsedMs: followup.elapsedMs,
          kind: followup.row.kind,
          handle: followup.row.attributeHandle ?? null,
          uuid: followup.row.uuid ?? null,
          valueHexPrefix: followup.row.valueHex?.slice(0, 80) ?? null,
          valueLength: followup.row.valueHex ? followup.row.valueHex.length / 2 : 0
        }));
      const responseTargets = uniqueStrings(responses.map((response) => response.uuid ?? (response.handle ? `handle=0x${response.handle.toString(16)}` : undefined)));
      return {
        timestamp: write.timestamp.toISOString(),
        connectionHandle: write.connectionHandle,
        handle: write.attributeHandle ?? null,
        uuid: write.uuid ?? null,
        operation: write.kind === "write_request" ? "write_with_response" : "write_without_response",
        valueHex: write.valueHex ?? "",
        responseTargets,
        responseCount: responses.length,
        responses: responses.slice(0, 8)
      };
    });
}

function printPlan(plan) {
  if (plan.length === 0) {
    console.log("No candidate command writes found.");
    return;
  }
  console.log("Candidate command plan:");
  for (const [index, step] of plan.entries()) {
    const target = step.uuid ?? (step.handle ? `handle=0x${step.handle.toString(16)}` : "unknown");
    console.log(`${index + 1}. ${step.operation} ${target} value=${step.valueHex}`);
    if (step.responseTargets.length > 0) {
      console.log(`   responses: ${step.responseTargets.join(", ")} (${step.responseCount} events within 5s)`);
    } else {
      console.log("   responses: none within 5s");
    }
    for (const response of step.responses.slice(0, 3)) {
      const responseTarget = response.uuid ?? (response.handle ? `handle=0x${response.handle.toString(16)}` : "unknown");
      console.log(`   +${response.elapsedMs}ms ${response.kind} ${responseTarget} bytes=${response.valueLength} value=${response.valueHexPrefix ?? ""}`);
    }
  }
}

function isPlanWrite(item) {
  const row = item.write;
  if (row.note || row.uuid === "2902") {
    return false;
  }
  if (!row.valueHex) {
    return false;
  }
  if (row.uuid && /FFF|5833/i.test(row.uuid)) {
    return true;
  }
  if (item.followups.some((followup) => followup.row.kind === "notification" || followup.row.kind === "indication")) {
    return true;
  }
  return row.valueHex.length <= 40;
}

function isInterestingWrite(row) {
  if (row.note) {
    return false;
  }
  if (!row.valueHex) {
    return false;
  }
  if (row.uuid && /FFF|5833/i.test(row.uuid)) {
    return true;
  }
  return row.valueHex.length <= 40;
}

function uniqueStrings(values) {
  return Array.from(new Set(values.filter((value) => typeof value === "string" && value.length > 0)));
}

function bluetoothAddress(bytes) {
  return Array.from(bytes)
    .reverse()
    .map((value) => value.toString(16).padStart(2, "0"))
    .join(":")
    .toUpperCase();
}

function formatRow(row) {
  const parts = [
    row.timestamp.toISOString(),
    row.direction,
    row.kind,
    `conn=0x${row.connectionHandle.toString(16)}`,
  ];
  if (row.attributeHandle) {
    parts.push(`handle=0x${row.attributeHandle.toString(16).padStart(4, "0")}`);
  }
  if (row.uuid) {
    parts.push(`uuid=${row.uuid}`);
  }
  if (row.valueHex) {
    parts.push(`value=${row.valueHex}`);
  }
  return parts.join(" ");
}

function jsonRow(row) {
  return {
    ...row,
    timestamp: row.timestamp.toISOString(),
  };
}

function jsonSummary(item) {
  return {
    write: jsonRow(item.write),
    followups: item.followups.map((followup) => ({
      elapsedMs: followup.elapsedMs,
      event: jsonRow(followup.row)
    }))
  };
}

function formatUUID(bytes) {
  if (bytes.length === 2) {
    return bytes.readUInt16LE(0).toString(16).padStart(4, "0").toUpperCase();
  }
  if (bytes.length === 16) {
    const b = Array.from(bytes).reverse().map((value) => value.toString(16).padStart(2, "0"));
    return `${b.slice(0, 4).join("")}-${b.slice(4, 6).join("")}-${b.slice(6, 8).join("")}-${b.slice(8, 10).join("")}-${b.slice(10).join("")}`.toUpperCase();
  }
  return hex(bytes);
}

function hex(buffer) {
  return Array.from(buffer).map((value) => value.toString(16).padStart(2, "0")).join("");
}

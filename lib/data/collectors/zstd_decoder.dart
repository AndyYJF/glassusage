import 'dart:convert';
import 'dart:typed_data';

const List<int> kZstdMagic = [0x28, 0xB5, 0x2F, 0xFD];

/// Incremental decoder for concatenated RFC 8878 Zstandard frames.
///
/// Returns `(bytesConsumed, decodedUtf8Frames)`. Any trailing incomplete frame
/// is left unconsumed so the caller's byte watermark only advances past
/// complete frames.
(int, List<String>) decodeCompleteZstdFrames(Uint8List buf) {
  var pos = 0;
  final frames = <String>[];
  while (pos < buf.length) {
    final rel = _findMagic(buf, pos);
    if (rel == null) break;
    final start = pos + rel;
    if (start > pos && frames.isEmpty && pos == 0) {
      // Skip leading garbage before first magic so truncated prefixes cannot stall.
      pos = start;
      continue;
    }
    final nextRel = _findMagic(buf, start + 4);
    final end = nextRel != null ? (start + 4 + nextRel) : buf.length;
    final frameBytes = Uint8List.sublistView(buf, start, end);
    final decoded = decodeOneZstdFrame(frameBytes);
    if (decoded == null) {
      // Incomplete trailing frame: wait for writer to finish.
      break;
    }
    frames.add(decoded);
    pos = end;
  }
  return (pos, frames);
}

int? _findMagic(Uint8List buf, int from) {
  final limit = buf.length - 4;
  for (var i = from; i <= limit; i++) {
    if (buf[i] == 0x28 &&
        buf[i + 1] == 0xB5 &&
        buf[i + 2] == 0x2F &&
        buf[i + 3] == 0xFD) {
      return i - from;
    }
  }
  return null;
}

String? decodeOneZstdFrame(Uint8List frame) {
  final bytes = decompressZstdFrameBytes(frame);
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return null;
  }
}

Uint8List? decompressZstdFrameBytes(Uint8List buf) {
  try {
    if (buf.length < 5) return null;
    if (buf[0] != 0x28 ||
        buf[1] != 0xB5 ||
        buf[2] != 0x2F ||
        buf[3] != 0xFD) {
      return null;
    }
    var pos = 4;
    final fhd = buf[pos++];
    final fcsFlag = (fhd >> 6) & 3;
    final singleSegment = ((fhd >> 5) & 1) != 0;
    final unusedBit = (fhd >> 4) & 1;
    final reservedBit = (fhd >> 3) & 1;
    final checksumFlag = ((fhd >> 2) & 1) != 0;
    final dictIdFlag = fhd & 3;
    if (unusedBit != 0 || reservedBit != 0) return null;

    if (!singleSegment) {
      if (pos >= buf.length) return null;
      pos++; // window descriptor
    }

    const dictSizes = [0, 1, 2, 4];
    final dictSize = dictSizes[dictIdFlag];
    if (pos + dictSize > buf.length) return null;
    pos += dictSize;

    int fcsSize;
    if (fcsFlag == 0) {
      fcsSize = singleSegment ? 1 : 0;
    } else if (fcsFlag == 1) {
      fcsSize = 2;
    } else if (fcsFlag == 2) {
      fcsSize = 4;
    } else {
      fcsSize = 8;
    }
    if (pos + fcsSize > buf.length) return null;
    pos += fcsSize;

    final out = BytesBuilder(copy: false);
    final window = <int>[];
    final state = _ZstdFrameState();

    var lastBlock = false;
    while (!lastBlock) {
      if (pos + 3 > buf.length) return null;
      final bh = buf[pos] | (buf[pos + 1] << 8) | (buf[pos + 2] << 16);
      pos += 3;
      lastBlock = (bh & 1) != 0;
      final blockType = (bh >> 1) & 3;
      final blockSize = bh >> 3;

      if (blockType == 0) {
        // Raw_Block
        if (pos + blockSize > buf.length) return null;
        final slice = Uint8List.sublistView(buf, pos, pos + blockSize);
        out.add(slice);
        window.addAll(slice);
        pos += blockSize;
      } else if (blockType == 1) {
        // RLE_Block
        if (pos + 1 > buf.length) return null;
        final b = buf[pos++];
        final slice = Uint8List(blockSize)..fillRange(0, blockSize, b);
        out.add(slice);
        window.addAll(slice);
      } else if (blockType == 2) {
        // Compressed_Block
        if (pos + blockSize > buf.length) return null;
        final blockBytes = _decompressBlock(
          Uint8List.sublistView(buf, pos, pos + blockSize),
          window,
          state,
        );
        if (blockBytes == null) return null;
        out.add(blockBytes);
        pos += blockSize;
      } else {
        return null;
      }
    }

    if (checksumFlag) {
      if (pos + 4 > buf.length) return null;
      pos += 4;
    }

    return out.toBytes();
  } catch (_) {
    return null;
  }
}

class _ZstdFrameState {
  List<int> rep = [1, 4, 8];
  _HufTable? hufTable;
  _FseTable? llTable;
  _FseTable? ofTable;
  _FseTable? mlTable;
}

Uint8List? _decompressBlock(
  Uint8List block,
  List<int> window,
  _ZstdFrameState state,
) {
  if (block.isEmpty) return null;
  var pos = 0;

  // 1. Literals_Section
  final h0 = block[pos];
  final litType = h0 & 3;
  final sizeFormat = (h0 >> 2) & 3;

  Uint8List literals;
  if (litType == 0 || litType == 1) {
    // Raw or RLE literals
    int regenSize;
    if (sizeFormat == 0 || sizeFormat == 2) {
      regenSize = h0 >> 3;
      pos += 1;
    } else if (sizeFormat == 1) {
      if (pos + 2 > block.length) return null;
      regenSize = (h0 >> 4) | (block[pos + 1] << 4);
      pos += 2;
    } else {
      if (pos + 3 > block.length) return null;
      regenSize = (h0 >> 4) | (block[pos + 1] << 4) | (block[pos + 2] << 12);
      pos += 3;
    }
    if (litType == 0) {
      if (pos + regenSize > block.length) return null;
      literals = Uint8List.sublistView(block, pos, pos + regenSize);
      pos += regenSize;
    } else {
      if (pos + 1 > block.length) return null;
      final b = block[pos++];
      literals = Uint8List(regenSize)..fillRange(0, regenSize, b);
    }
  } else {
    // Compressed (2) or Treeless (3) literals
    final numStreams = sizeFormat == 0 ? 1 : 4;
    int regenSize;
    int compSize;
    if (sizeFormat == 0 || sizeFormat == 1) {
      if (pos + 3 > block.length) return null;
      final v = block[pos] | (block[pos + 1] << 8) | (block[pos + 2] << 16);
      regenSize = (v >> 4) & 0x3FF;
      compSize = (v >> 14) & 0x3FF;
      pos += 3;
    } else if (sizeFormat == 2) {
      if (pos + 4 > block.length) return null;
      final v = block[pos] |
          (block[pos + 1] << 8) |
          (block[pos + 2] << 16) |
          (block[pos + 3] << 24);
      regenSize = (v >> 4) & 0x3FFF;
      compSize = (v >> 18) & 0x3FFF;
      pos += 4;
    } else {
      if (pos + 5 > block.length) return null;
      final v = block[pos] |
          (block[pos + 1] << 8) |
          (block[pos + 2] << 16) |
          (block[pos + 3] << 24) |
          (block[pos + 4] << 32);
      regenSize = (v >> 4) & 0x3FFFF;
      compSize = (v >> 22) & 0x3FFFF;
      pos += 5;
    }
    if (pos + compSize > block.length) return null;
    final litEnd = pos + compSize;
    var streamStart = pos;
    if (litType == 2) {
      final treeRes = _readHuffmanTree(block, streamStart, litEnd);
      if (treeRes == null) return null;
      state.hufTable = treeRes.$1;
      streamStart += treeRes.$2;
    }
    final huf = state.hufTable;
    if (huf == null) return null;

    literals = Uint8List(regenSize);
    if (numStreams == 1) {
      if (!_decodeHufStream(
        huf,
        block,
        streamStart,
        litEnd,
        literals,
        0,
        regenSize,
      )) {
        return null;
      }
    } else {
      if (streamStart + 6 > litEnd) return null;
      final s1 = block[streamStart] | (block[streamStart + 1] << 8);
      final s2 = block[streamStart + 2] | (block[streamStart + 3] << 8);
      final s3 = block[streamStart + 4] | (block[streamStart + 5] << 8);
      final p1 = streamStart + 6;
      final p2 = p1 + s1;
      final p3 = p2 + s2;
      final p4 = p3 + s3;
      if (p4 > litEnd) return null;
      final chunk = (regenSize + 3) >> 2;
      final c1 = chunk.clamp(0, regenSize);
      final c2 = (regenSize - c1).clamp(0, chunk);
      final c3 = (regenSize - c1 - c2).clamp(0, chunk);
      final c4 = regenSize - c1 - c2 - c3;
      if (!_decodeHufStream(huf, block, p1, p2, literals, 0, c1)) return null;
      if (!_decodeHufStream(huf, block, p2, p3, literals, c1, c2)) return null;
      if (!_decodeHufStream(huf, block, p3, p4, literals, c1 + c2, c3)) {
        return null;
      }
      if (!_decodeHufStream(
        huf,
        block,
        p4,
        litEnd,
        literals,
        c1 + c2 + c3,
        c4,
      )) {
        return null;
      }
    }
    pos = litEnd;
  }

  // 2. Sequences_Section
  if (pos >= block.length) return null;
  final seqByte0 = block[pos++];
  int numSeqs;
  if (seqByte0 == 0) {
    if (pos != block.length) return null;
    window.addAll(literals);
    return literals;
  } else if (seqByte0 < 128) {
    numSeqs = seqByte0;
  } else if (seqByte0 < 255) {
    if (pos >= block.length) return null;
    numSeqs = ((seqByte0 - 128) << 8) + block[pos++];
  } else {
    if (pos + 2 > block.length) return null;
    numSeqs = block[pos] + (block[pos + 1] << 8) + 0x7F00;
    pos += 2;
  }

  if (pos >= block.length) return null;
  final modes = block[pos++];
  if ((modes & 3) != 0) return null;
  final llMode = (modes >> 6) & 3;
  final ofMode = (modes >> 4) & 3;
  final mlMode = (modes >> 2) & 3;

  final llRes = _resolveSeqTable(
    llMode,
    block,
    pos,
    35,
    9,
    _defaultLlTable,
    state.llTable,
  );
  if (llRes == null) return null;
  state.llTable = llRes.$1;
  pos += llRes.$2;

  final ofRes = _resolveSeqTable(
    ofMode,
    block,
    pos,
    31,
    8,
    _defaultOfTable,
    state.ofTable,
  );
  if (ofRes == null) return null;
  state.ofTable = ofRes.$1;
  pos += ofRes.$2;

  final mlRes = _resolveSeqTable(
    mlMode,
    block,
    pos,
    52,
    9,
    _defaultMlTable,
    state.mlTable,
  );
  if (mlRes == null) return null;
  state.mlTable = mlRes.$1;
  pos += mlRes.$2;

  if (pos >= block.length) return null;
  final bits = _BackwardBitStream.init(block, pos, block.length);
  if (bits == null) return null;

  final llTable = state.llTable!;
  final ofTable = state.ofTable!;
  final mlTable = state.mlTable!;

  var llState = bits.read(llTable.accuracyLog);
  var ofState = bits.read(ofTable.accuracyLog);
  var mlState = bits.read(mlTable.accuracyLog);

  final blockStartInWindow = window.length;
  var litPos = 0;

  for (var seqIdx = 0; seqIdx < numSeqs; seqIdx++) {
    final llCode = llTable.symbol[llState];
    final mlCode = mlTable.symbol[mlState];
    final ofCode = ofTable.symbol[ofState];

    if (llCode > 35 || mlCode > 52 || ofCode > 31) return null;

    // Decode offset, matchLength, litLength in RFC 8878 order:
    // Offset extra bits -> MatchLength extra bits -> LitLength extra bits.
    final ofRaw = (1 << ofCode) + bits.read(ofCode);
    final mlVal = _mlBase[mlCode] + bits.read(_mlBits[mlCode]);
    final llVal = _llBase[llCode] + bits.read(_llBits[llCode]);

    int offset;
    if (ofRaw > 3) {
      offset = ofRaw - 3;
      state.rep[2] = state.rep[1];
      state.rep[1] = state.rep[0];
      state.rep[0] = offset;
    } else {
      final repIdx = ofRaw - 1 + (llVal == 0 ? 1 : 0);
      if (repIdx == 3) {
        offset = state.rep[0] - 1;
      } else {
        offset = state.rep[repIdx];
      }
      if (offset <= 0) return null;
      if (repIdx >= 2) {
        state.rep[2] = state.rep[1];
      }
      if (repIdx >= 1) {
        state.rep[1] = state.rep[0];
      }
      state.rep[0] = offset;
    }

    // Copy literals
    if (litPos + llVal > literals.length) return null;
    for (var i = 0; i < llVal; i++) {
      window.add(literals[litPos + i]);
    }
    litPos += llVal;

    // Execute match copy
    var matchSrc = window.length - offset;
    if (matchSrc < 0) return null;
    for (var i = 0; i < mlVal; i++) {
      window.add(window[matchSrc + i]);
    }

    // Update FSE states if not the last sequence
    if (seqIdx + 1 < numSeqs) {
      final llNb = llTable.numBits[llState];
      final mlNb = mlTable.numBits[mlState];
      final ofNb = ofTable.numBits[ofState];
      llState = llTable.newStateBase[llState] + bits.read(llNb);
      mlState = mlTable.newStateBase[mlState] + bits.read(mlNb);
      ofState = ofTable.newStateBase[ofState] + bits.read(ofNb);
    }
  }

  // Append remaining literals
  while (litPos < literals.length) {
    window.add(literals[litPos++]);
  }

  return Uint8List.fromList(window.sublist(blockStartInWindow));
}

// ------------------------------------------------------------------ Huffman

class _HufTable {
  final int maxBits;
  final Uint8List symbol;
  final Uint8List numBits;

  _HufTable(this.maxBits, this.symbol, this.numBits);
}

(_HufTable, int)? _readHuffmanTree(Uint8List buf, int start, int limit) {
  if (start >= limit) return null;
  final headerByte = buf[start];
  final weights = <int>[];
  int bytesConsumed;

  if (headerByte >= 128) {
    final numWeights = headerByte - 127;
    final bodyBytes = (numWeights + 1) >> 1;
    bytesConsumed = 1 + bodyBytes;
    if (start + bytesConsumed > limit) return null;
    for (var i = 0; i < numWeights; i++) {
      final b = buf[start + 1 + (i >> 1)];
      weights.add((i & 1) == 0 ? (b >> 4) : (b & 0x0F));
    }
  } else {
    final compSize = headerByte;
    bytesConsumed = 1 + compSize;
    if (start + bytesConsumed > limit) return null;
    final fseRes = _readFseTable(buf, start + 1, start + bytesConsumed, 12, 6);
    if (fseRes == null) return null;
    final fse = fseRes.$1;
    final hdrSize = fseRes.$2;
    final streamStart = start + 1 + hdrSize;
    final streamEnd = start + bytesConsumed;
    final bits = _BackwardBitStream.init(buf, streamStart, streamEnd);
    if (bits == null) return null;
    var state1 = bits.read(fse.accuracyLog);
    var state2 = bits.read(fse.accuracyLog);
    while (weights.length < 255) {
      weights.add(fse.symbol[state1]);
      final n1 = fse.numBits[state1];
      if (bits.bitsLeft < n1) {
        weights.add(fse.symbol[state2]);
        break;
      }
      state1 = fse.newStateBase[state1] + bits.read(n1);

      weights.add(fse.symbol[state2]);
      final n2 = fse.numBits[state2];
      if (bits.bitsLeft < n2) {
        weights.add(fse.symbol[state1]);
        break;
      }
      state2 = fse.newStateBase[state2] + bits.read(n2);
    }
  }

  var weightSum = 0;
  for (final w in weights) {
    if (w > 11) return null;
    if (w > 0) weightSum += 1 << (w - 1);
  }
  if (weightSum == 0) return null;
  final maxBits = _highBit(weightSum) + 1;
  if (maxBits > 11) return null;
  final totalWeight = 1 << maxBits;
  final leftOver = totalWeight - weightSum;
  if (leftOver <= 0 || (leftOver & (leftOver - 1)) != 0) return null;
  final lastWeight = _highBit(leftOver) + 1;
  weights.add(lastWeight);

  final rankCount = List<int>.filled(maxBits + 1, 0);
  for (final w in weights) {
    if (w > 0) rankCount[w]++;
  }

  final rankIdx = List<int>.filled(maxBits + 1, 0);
  var idx = 0;
  for (var w = 1; w <= maxBits; w++) {
    rankIdx[w] = idx;
    idx += rankCount[w] * (1 << (w - 1));
  }
  if (idx != totalWeight) return null;

  final symTable = Uint8List(totalWeight);
  final nbTable = Uint8List(totalWeight);
  for (var sym = 0; sym < weights.length; sym++) {
    final w = weights[sym];
    if (w == 0) continue;
    final nb = maxBits + 1 - w;
    final len = 1 << (w - 1);
    final base = rankIdx[w];
    for (var i = 0; i < len; i++) {
      symTable[base + i] = sym;
      nbTable[base + i] = nb;
    }
    rankIdx[w] += len;
  }

  return (_HufTable(maxBits, symTable, nbTable), bytesConsumed);
}

bool _decodeHufStream(
  _HufTable huf,
  Uint8List buf,
  int start,
  int end,
  Uint8List out,
  int outOffset,
  int outLen,
) {
  if (outLen == 0) return true;
  final bits = _BackwardBitStream.init(buf, start, end);
  if (bits == null) return false;
  for (var i = 0; i < outLen; i++) {
    final code = bits.peek(huf.maxBits);
    out[outOffset + i] = huf.symbol[code];
    bits.consume(huf.numBits[code]);
  }
  return bits.bitsLeft == 0;
}

// ------------------------------------------------------------------ FSE

class _FseTable {
  final int accuracyLog;
  final Uint8List symbol;
  final Uint8List numBits;
  final Int32List newStateBase;

  _FseTable(this.accuracyLog, this.symbol, this.numBits, this.newStateBase);

  factory _FseTable.rle(int sym) {
    return _FseTable(
      0,
      Uint8List.fromList([sym]),
      Uint8List.fromList([0]),
      Int32List.fromList([0]),
    );
  }
}

(_FseTable, int)? _resolveSeqTable(
  int mode,
  Uint8List buf,
  int pos,
  int maxSymbol,
  int maxLog,
  _FseTable predefined,
  _FseTable? previous,
) {
  if (mode == 0) {
    return (predefined, 0);
  } else if (mode == 1) {
    if (pos >= buf.length) return null;
    return (_FseTable.rle(buf[pos]), 1);
  } else if (mode == 2) {
    return _readFseTable(buf, pos, buf.length, maxSymbol, maxLog);
  } else {
    if (previous == null) return null;
    return (previous, 0);
  }
}

(_FseTable, int)? _readFseTable(
  Uint8List buf,
  int start,
  int limit,
  int maxSymbol,
  int maxLog,
) {
  if (start >= limit) return null;
  var bitPos = 0;

  int peekBits(int n) {
    if (n <= 0) return 0;
    final byteIdx = start + (bitPos >> 3);
    final bitShift = bitPos & 7;
    var val = 0;
    for (var i = 0; i < 4; i++) {
      final b = (byteIdx + i < limit) ? buf[byteIdx + i] : 0;
      val |= b << (i * 8);
    }
    return (val >> bitShift) & ((1 << n) - 1);
  }

  int readBits(int n) {
    final v = peekBits(n);
    bitPos += n;
    return v;
  }

  final accuracyLog = readBits(4) + 5;
  if (accuracyLog > maxLog) return null;
  var remaining = (1 << accuracyLog) + 1;
  var threshold = 1 << accuracyLog;
  var nbBits = accuracyLog + 1;
  final counts = List<int>.filled(maxSymbol + 1, 0);
  var charnum = 0;
  var prev0 = false;

  while (remaining > 1 && charnum <= maxSymbol) {
    if (prev0) {
      while (true) {
        final r = readBits(2);
        charnum += r;
        if (r != 3) break;
      }
      if (charnum > maxSymbol) break;
    }
    final max = (2 * threshold - 1) - remaining;
    final low = peekBits(nbBits - 1);
    int count;
    if (low < max) {
      bitPos += nbBits - 1;
      count = low - 1;
    } else {
      var val = readBits(nbBits);
      if (val >= threshold) val -= max;
      count = val - 1;
    }
    counts[charnum++] = count;
    prev0 = count == 0;
    if (count != 0) {
      remaining -= count > 0 ? count : 1;
      if (remaining < 1) return null;
      while (remaining < threshold && nbBits > 1) {
        nbBits--;
        threshold >>= 1;
      }
    }
  }
  if (remaining != 1) return null;
  final bytesConsumed = (bitPos + 7) >> 3;
  if (start + bytesConsumed > limit) return null;
  final table = _buildFseTable(accuracyLog, counts);
  if (table == null) return null;
  return (table, bytesConsumed);
}

_FseTable? _buildFseTable(int accuracyLog, List<int> counts) {
  final tableSize = 1 << accuracyLog;
  final tableMask = tableSize - 1;
  final step = (tableSize >> 1) + (tableSize >> 3) + 3;
  final symbol = Uint8List(tableSize);
  final symbolNext = Int32List(counts.length);

  var highThreshold = tableSize - 1;
  for (var s = 0; s < counts.length; s++) {
    if (counts[s] == -1) {
      if (highThreshold < 0) return null;
      symbol[highThreshold--] = s;
      symbolNext[s] = 1;
    }
  }

  var pos = 0;
  for (var s = 0; s < counts.length; s++) {
    final c = counts[s];
    if (c <= 0) continue;
    symbolNext[s] = c;
    for (var i = 0; i < c; i++) {
      symbol[pos] = s;
      do {
        pos = (pos + step) & tableMask;
      } while (pos > highThreshold);
    }
  }
  if (pos != 0) return null;

  final numBits = Uint8List(tableSize);
  final newStateBase = Int32List(tableSize);
  for (var i = 0; i < tableSize; i++) {
    final s = symbol[i];
    final nextState = symbolNext[s]++;
    final nb = accuracyLog - _highBit(nextState);
    numBits[i] = nb;
    newStateBase[i] = (nextState << nb) - tableSize;
  }

  return _FseTable(accuracyLog, symbol, numBits, newStateBase);
}

// ------------------------------------------------------------------ Bitstream

class _BackwardBitStream {
  final Uint8List buf;
  final int start;
  int bitPos;

  _BackwardBitStream(this.buf, this.start, this.bitPos);

  static _BackwardBitStream? init(Uint8List buf, int start, int end) {
    if (start >= end) return null;
    final last = buf[end - 1];
    if (last == 0) return null;
    final hb = _highBit(last);
    final totalBits = (end - start - 1) * 8 + hb;
    return _BackwardBitStream(buf, start, totalBits);
  }

  int get bitsLeft => bitPos;

  int peek(int n) {
    if (n <= 0) return 0;
    var val = 0;
    for (var i = 0; i < n; i++) {
      final bIdx = bitPos - 1 - i;
      int bit = 0;
      if (bIdx >= 0) {
        final byteOffset = start + (bIdx >> 3);
        final bitOffset = bIdx & 7;
        bit = (buf[byteOffset] >> bitOffset) & 1;
      }
      val = (val << 1) | bit;
    }
    return val;
  }

  void consume(int n) {
    bitPos -= n;
  }

  int read(int n) {
    final v = peek(n);
    bitPos -= n;
    return v;
  }
}

int _highBit(int n) {
  var r = 0;
  var v = n;
  while (v > 1) {
    v >>= 1;
    r++;
  }
  return r;
}

// ------------------------------------------------------------------ Predefined Tables (RFC 8878 §3.1.1.3.2.2)

final _FseTable _defaultLlTable = _buildFseTable(6, const [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
  2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
  -1, -1, -1, -1,
])!;

final _FseTable _defaultMlTable = _buildFseTable(6, const [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
  -1, -1, -1, -1, -1,
])!;

final _FseTable _defaultOfTable = _buildFseTable(5, const [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
])!;

const List<int> _llBase = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
  8192, 16384, 32768, 65536,
];

const List<int> _llBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
  13, 14, 15, 16,
];

const List<int> _mlBase = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
  19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
  35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
  4099, 8195, 16387, 32771, 65539,
];

const List<int> _mlBits = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
  12, 13, 14, 15, 16,
];

import 'dart:convert';
import 'dart:typed_data';

/// Minimal protobuf wire-format reader matching `protoscan.rs` for Antigravity IDE blobs.
sealed class ProtoValue {
  const ProtoValue();
}

class ProtoVarint extends ProtoValue {
  final int value;
  const ProtoVarint(this.value);
}

class ProtoFixed64 extends ProtoValue {
  final int value;
  const ProtoFixed64(this.value);
}

class ProtoFixed32 extends ProtoValue {
  final int value;
  const ProtoFixed32(this.value);
}

class ProtoBytes extends ProtoValue {
  final Uint8List bytes;
  const ProtoBytes(this.bytes);
}

class ProtoSubMessage extends ProtoValue {
  final ProtoMessage message;
  const ProtoSubMessage(this.message);
}

class ProtoMessage {
  final List<(int, ProtoValue)> fields;
  final Uint8List? raw;

  const ProtoMessage({
    this.fields = const [],
    this.raw,
  });

  ProtoValue? get(int field) {
    for (final (f, v) in fields) {
      if (f == field) return v;
    }
    return null;
  }

  Iterable<ProtoValue> getAll(int field) sync* {
    for (final (f, v) in fields) {
      if (f == field) yield v;
    }
  }

  ProtoMessage? message(int field) {
    final v = get(field);
    if (v is ProtoSubMessage) return v.message;
    return null;
  }

  int varint(int field) {
    final v = get(field);
    if (v is ProtoVarint) return v.value;
    return 0;
  }

  String? string(int field) {
    final v = get(field);
    if (v is ProtoBytes) {
      try {
        return utf8.decode(v.bytes, allowMalformed: false);
      } catch (_) {
        return null;
      }
    }
    if (v is ProtoSubMessage && v.message.raw != null) {
      try {
        return utf8.decode(v.message.raw!, allowMalformed: false);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  ProtoMessage? path(List<int> fieldPath) {
    ProtoMessage? cur = this;
    for (final f in fieldPath) {
      cur = cur?.message(f);
      if (cur == null) return null;
    }
    return cur;
  }
}

const int _kMaxDepth = 8;

ProtoMessage? decodeProtobuf(Uint8List buf) => _decodeInner(buf, 0, null);

ProtoMessage? _decodeInner(Uint8List buf, int depth, Uint8List? rawBytes) {
  final fields = <(int, ProtoValue)>[];
  var pos = 0;

  while (pos < buf.length) {
    final keyRes = _readVarint(buf, pos);
    if (keyRes == null) return null;
    final (key, nextPos) = keyRes;
    pos = nextPos;
    final fieldNo = key >>> 3;
    final wire = key & 7;
    if (fieldNo == 0) return null;

    switch (wire) {
      case 0:
        final valRes = _readVarint(buf, pos);
        if (valRes == null) return null;
        pos = valRes.$2;
        fields.add((fieldNo, ProtoVarint(valRes.$1)));
      case 1:
        if (pos + 8 > buf.length) return null;
        final bd = ByteData.sublistView(buf, pos, pos + 8);
        final v = bd.getUint64(0, Endian.little);
        pos += 8;
        fields.add((fieldNo, ProtoFixed64(v)));
      case 5:
        if (pos + 4 > buf.length) return null;
        final bd = ByteData.sublistView(buf, pos, pos + 4);
        final v = bd.getUint32(0, Endian.little);
        pos += 4;
        fields.add((fieldNo, ProtoFixed32(v)));
      case 2:
        final lenRes = _readVarint(buf, pos);
        if (lenRes == null) return null;
        final len = lenRes.$1;
        pos = lenRes.$2;
        if (len < 0 || pos + len > buf.length) return null;
        final sub = Uint8List.sublistView(buf, pos, pos + len);
        pos += len;
        ProtoValue value;
        if (depth < _kMaxDepth && len > 1) {
          final nested = _decodeInner(sub, depth + 1, sub);
          value = nested != null ? ProtoSubMessage(nested) : ProtoBytes(sub);
        } else {
          value = ProtoBytes(sub);
        }
        fields.add((fieldNo, value));
      default:
        return null;
    }
  }

  return ProtoMessage(fields: fields, raw: rawBytes);
}

(int, int)? _readVarint(Uint8List buf, int startPos) {
  var pos = startPos;
  var result = 0;
  var shift = 0;
  while (pos < buf.length) {
    final b = buf[pos];
    pos += 1;
    result |= (b & 0x7f) << shift;
    if ((b & 0x80) == 0) {
      return (result, pos);
    }
    shift += 7;
    if (shift > 63) return null;
  }
  return null;
}

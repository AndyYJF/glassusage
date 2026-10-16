import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _CryptDataBlob extends ffi.Struct {
  @ffi.Uint32()
  external int cbData;

  external ffi.Pointer<ffi.Uint8> pbData;
}

typedef _CryptProtectDataNative = ffi.Int32 Function(
  ffi.Pointer<_CryptDataBlob> pDataIn,
  ffi.Pointer<ffi.WChar> szDataDescr,
  ffi.Pointer<_CryptDataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  ffi.Uint32 dwFlags,
  ffi.Pointer<_CryptDataBlob> pDataOut,
);

typedef _CryptProtectDataDart = int Function(
  ffi.Pointer<_CryptDataBlob> pDataIn,
  ffi.Pointer<ffi.WChar> szDataDescr,
  ffi.Pointer<_CryptDataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  int dwFlags,
  ffi.Pointer<_CryptDataBlob> pDataOut,
);

typedef _CryptUnprotectDataNative = ffi.Int32 Function(
  ffi.Pointer<_CryptDataBlob> pDataIn,
  ffi.Pointer<ffi.Pointer<ffi.WChar>> ppszDataDescr,
  ffi.Pointer<_CryptDataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  ffi.Uint32 dwFlags,
  ffi.Pointer<_CryptDataBlob> pDataOut,
);

typedef _CryptUnprotectDataDart = int Function(
  ffi.Pointer<_CryptDataBlob> pDataIn,
  ffi.Pointer<ffi.Pointer<ffi.WChar>> ppszDataDescr,
  ffi.Pointer<_CryptDataBlob> pOptionalEntropy,
  ffi.Pointer<ffi.Void> pvReserved,
  ffi.Pointer<ffi.Void> pPromptStruct,
  int dwFlags,
  ffi.Pointer<_CryptDataBlob> pDataOut,
);

typedef _LocalFreeNative = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Void> hMem,
);
typedef _LocalFreeDart = ffi.Pointer<ffi.Void> Function(
  ffi.Pointer<ffi.Void> hMem,
);

/// Windows DPAPI wrappers for encrypting and decrypting sensitive tokens
/// (Cursor session token and remote SSH passwords) bound to the current user.
class Dpapi {
  static final ffi.DynamicLibrary _crypt32 =
      ffi.DynamicLibrary.open('crypt32.dll');
  static final ffi.DynamicLibrary _kernel32 =
      ffi.DynamicLibrary.open('kernel32.dll');

  static final _CryptProtectDataDart _cryptProtectData = _crypt32
      .lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
        'CryptProtectData',
      );

  static final _CryptUnprotectDataDart _cryptUnprotectData = _crypt32
      .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
        'CryptUnprotectData',
      );

  static final _LocalFreeDart _localFree = _kernel32
      .lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');

  static Uint8List protect(Uint8List plaintext) {
    if (!Platform.isWindows) {
      throw UnsupportedError('credential storage requires Windows DPAPI');
    }
    return using((arena) {
      final inPtr = arena<ffi.Uint8>(plaintext.isEmpty ? 1 : plaintext.length);
      if (plaintext.isNotEmpty) {
        inPtr.asTypedList(plaintext.length).setAll(0, plaintext);
      }
      final input = arena<_CryptDataBlob>();
      input.ref.cbData = plaintext.length;
      input.ref.pbData = inPtr;

      final output = arena<_CryptDataBlob>();
      final ok = _cryptProtectData(
        input,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        0,
        output,
      );
      if (ok == 0) {
        throw StateError('CryptProtectData failed');
      }
      try {
        final len = output.ref.cbData;
        final outSlice = output.ref.pbData.asTypedList(len);
        return Uint8List.fromList(outSlice);
      } finally {
        _localFree(output.ref.pbData.cast());
      }
    });
  }

  static Uint8List unprotect(Uint8List ciphertext) {
    if (!Platform.isWindows) {
      throw UnsupportedError('credential storage requires Windows DPAPI');
    }
    return using((arena) {
      final inPtr =
          arena<ffi.Uint8>(ciphertext.isEmpty ? 1 : ciphertext.length);
      if (ciphertext.isNotEmpty) {
        inPtr.asTypedList(ciphertext.length).setAll(0, ciphertext);
      }
      final input = arena<_CryptDataBlob>();
      input.ref.cbData = ciphertext.length;
      input.ref.pbData = inPtr;

      final output = arena<_CryptDataBlob>();
      final ok = _cryptUnprotectData(
        input,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        ffi.nullptr,
        0,
        output,
      );
      if (ok == 0) {
        throw StateError('CryptUnprotectData failed');
      }
      try {
        final len = output.ref.cbData;
        final outSlice = output.ref.pbData.asTypedList(len);
        return Uint8List.fromList(outSlice);
      } finally {
        _localFree(output.ref.pbData.cast());
      }
    });
  }

  static Uint8List protectStr(String s) {
    return protect(Uint8List.fromList(utf8.encode(s)));
  }

  static String unprotectStr(Uint8List b) {
    return utf8.decode(unprotect(b));
  }
}

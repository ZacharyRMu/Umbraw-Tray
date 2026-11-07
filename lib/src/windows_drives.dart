// Windows-only: list drive letters that Windows reports as removable.
//
// Uses kernel32 directly through dart:ffi. Only call these on Windows.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _NoArgsC = Uint32 Function();
typedef _NoArgsDart = int Function();
typedef _DriveTypeC = Uint32 Function(Pointer<Utf16>);
typedef _DriveTypeDart = int Function(Pointer<Utf16>);
typedef _ErrorModeC = Uint32 Function(Uint32);
typedef _ErrorModeDart = int Function(int);

const _driveRemovable = 2;
const _semFailCriticalErrors = 0x0001;

DynamicLibrary? _kernel32;
bool _errorModeSet = false;

DynamicLibrary get _k32 => _kernel32 ??= DynamicLibrary.open('kernel32.dll');

List<String> windowsRemovableDrives() {
  // Stop Windows from popping "There is no disk in the drive" dialogs when an
  // empty card-reader slot is probed.
  if (!_errorModeSet) {
    _k32.lookupFunction<_ErrorModeC, _ErrorModeDart>('SetErrorMode')(
        _semFailCriticalErrors);
    _errorModeSet = true;
  }

  final getLogicalDrives =
      _k32.lookupFunction<_NoArgsC, _NoArgsDart>('GetLogicalDrives');
  final getDriveType =
      _k32.lookupFunction<_DriveTypeC, _DriveTypeDart>('GetDriveTypeW');

  final mask = getLogicalDrives();
  final found = <String>[];
  for (var i = 0; i < 26; i++) {
    if ((mask & (1 << i)) == 0) continue;
    final root = '${String.fromCharCode(65 + i)}:\\';
    final ptr = root.toNativeUtf16();
    try {
      if (getDriveType(ptr) == _driveRemovable) found.add(root);
    } finally {
      malloc.free(ptr);
    }
  }
  return found;
}

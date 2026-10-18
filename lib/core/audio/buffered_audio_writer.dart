import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Coalesces headers and short speech spans into bounded 256 KiB writes.
/// Callers await each write so the file and buffer never have concurrent users.
class BufferedAudioWriter {
  BufferedAudioWriter(this._file);

  final RandomAccessFile _file;
  final _buffer = Uint8List(256 * 1024);
  int _fill = 0;

  Future<void> write(Uint8List bytes) async {
    var offset = 0;
    while (offset < bytes.length) {
      final length = math.min(_buffer.length - _fill, bytes.length - offset);
      _buffer.setRange(_fill, _fill + length, bytes, offset);
      _fill += length;
      offset += length;
      if (_fill == _buffer.length) {
        _fill = 0;
        await _file.writeFrom(_buffer);
      }
    }
  }

  Future<void> close() async {
    try {
      if (_fill > 0) await _file.writeFrom(_buffer, 0, _fill);
    } finally {
      await _file.close();
    }
  }
}

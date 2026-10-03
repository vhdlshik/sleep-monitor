import 'dart:io';
import 'dart:typed_data';

/// Streams 16-bit mono PCM into a WAV file, fixing up the header on close.
class WavWriter {
  WavWriter._(this._file, this.sampleRate);

  static Future<WavWriter> open(String path, {required int sampleRate}) async {
    final file = await File(path).open(mode: FileMode.write);
    final writer = WavWriter._(file, sampleRate);
    await file.writeFrom(writer._header(0));
    return writer;
  }

  final RandomAccessFile _file;
  final int sampleRate;
  int _dataBytes = 0;

  Future<void> add(Uint8List pcm) async {
    await _file.writeFrom(pcm);
    _dataBytes += pcm.length;
  }

  Future<void> close() async {
    await _file.setPosition(0);
    await _file.writeFrom(_header(_dataBytes));
    await _file.close();
  }

  Uint8List _header(int dataBytes) {
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final b = ByteData(44);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        b.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    b.setUint32(4, 36 + dataBytes, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    b.setUint32(16, 16, Endian.little);
    b.setUint16(20, 1, Endian.little); // PCM
    b.setUint16(22, channels, Endian.little);
    b.setUint32(24, sampleRate, Endian.little);
    b.setUint32(28, byteRate, Endian.little);
    b.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
    b.setUint16(34, bitsPerSample, Endian.little);
    ascii(36, 'data');
    b.setUint32(40, dataBytes, Endian.little);
    return b.buffer.asUint8List();
  }
}

/// Keeps the last few seconds of audio so a recording can include what
/// happened just before it was triggered.
class PreRollBuffer {
  PreRollBuffer(this.maxFrames);

  final int maxFrames;
  final List<Uint8List> _frames = [];

  int get length => _frames.length;

  void add(Uint8List frame) {
    _frames.add(frame);
    if (_frames.length > maxFrames) _frames.removeAt(0);
  }

  /// Returns the buffered frames, oldest first, and empties the buffer.
  List<Uint8List> drain() {
    final out = List<Uint8List>.of(_frames);
    _frames.clear();
    return out;
  }
}

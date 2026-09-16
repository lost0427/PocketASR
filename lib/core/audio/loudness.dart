import 'dart:math' as math;
import 'dart:typed_data';
import 'pcm_file.dart';

/// BS.1770-4 integrated loudness measurement and gain normalization.
///
/// Scope: mono 16 kHz (the pipeline's canonical format). K-weighting biquads
/// are re-derived by bilinear transform for the caller's [sampleRate], so the
/// 48 kHz coefficient table from the standard is *not* hard-coded.
///
/// Limitations (also reported with the Phase 3 result):
/// * Mono only. Multi-channel G-weighting is not implemented.
/// * Block loudness below 400 ms falls back to a single whole-input block.
/// * "True peak" is a compact 4x windowed-sinc estimate, not the full
///   BS.1770 Annex 2 interpolator.
class LoudnessNormalizer {
  const LoudnessNormalizer({
    this.targetLufs = -16.0,
    this.maxGainDb = 30.0,
    this.truePeakCeilingDb = -1.0,
  });

  /// Integrated loudness to hit. -16 is a good speech/ASR target; -14 / -23
  /// are the other common settings.
  final double targetLufs;

  /// Upper bound on any boost, so a quiet-but-not-silent take cannot turn the
  /// noise floor into a wall of hiss.
  final double maxGainDb;

  /// Estimated true peak is not allowed above this after gain.
  final double truePeakCeilingDb;

  /// Two bounded scans retain filter history and apply one gain to the file.
  Future<({double lufs, double gainDb})> measureFile(PcmFile file, {
    bool Function()? isCancelled,
  }) async {
    Future<double> gated(double gate) async {
      var sum = 0.0;
      var count = 0;
      await for (final energy in _fileEnergies(file, isCancelled)) {
        if (_lufs(energy) > gate) { sum += energy; count++; }
      }
      return count == 0 ? double.negativeInfinity : _lufs(sum / count);
    }
    final absolute = await gated(_absoluteGateLufs);
    if (!absolute.isFinite) return (lufs: absolute, gainDb: 0.0);
    final integrated = await gated(math.max(_absoluteGateLufs, absolute - _relativeGateLu));
    var peak = double.negativeInfinity;
    // Halo keeps the true-peak interpolator continuous across read boundaries.
    const size = 16384;
    for (var at = 0; at < file.count; at += size) {
      await for (final block in file.blocks(start: math.max(0, at - 8),
          end: math.min(file.count, at + size + 8), blockSize: size + 16,
          isCancelled: isCancelled)) {
        final amplitude = _truePeak(block, start: at == 0 ? 0 : 8,
          end: math.min(block.length, (at == 0 ? 0 : 8) + math.min(size, file.count - at)));
        if (amplitude > 0) peak = math.max(peak, 20 * _log10(amplitude));
      }
    }
    return (lufs: integrated, gainDb: math.min(math.min(targetLufs - integrated, maxGainDb),
      peak.isFinite ? truePeakCeilingDb - peak : double.infinity));
  }

  /// BS.1770-4 integrated loudness in LUFS. [double.negativeInfinity] when the
  /// signal is silent / entirely below the -70 LUFS absolute gate.
  double integratedLufs(Float32List samples, {int sampleRate = 16000}) {
    if (sampleRate <= 0) return double.negativeInfinity;
    return _gatedLoudness(_blockMeanSquares(samples, sampleRate));
  }

  /// Gain in dB that normalization would apply right now. 0 for silence.
  double gainDbFor(Float32List samples, {int sampleRate = 16000}) {
    final integrated = integratedLufs(samples, sampleRate: sampleRate);
    if (!integrated.isFinite) return 0.0; // silence: never amplify noise

    var gain = targetLufs - integrated;
    if (gain > maxGainDb) gain = maxGainDb;

    // Peak protection: back the gain off if the boosted true peak would pass
    // the ceiling. Uses the estimator below, so measure === apply.
    final peak = truePeakDb(samples);
    if (peak.isFinite) {
      final allowed = truePeakCeilingDb - peak;
      if (gain > allowed) gain = allowed;
    }
    return gain;
  }

  /// Applies normalization in place and returns the applied gain in dB.
  double normalizeInPlace(Float32List samples, {int sampleRate = 16000}) {
    final gain = gainDbFor(samples, sampleRate: sampleRate);
    if (gain == 0.0) return 0.0; // silent (or exact target/peak): leave as is

    final g = math.pow(10, gain / 20).toDouble();
    for (var i = 0; i < samples.length; i++) {
      samples[i] = (samples[i] * g).clamp(-1.0, 1.0);
    }
    return gain;
  }
}

// --- Loudness internals -----------------------------------------------------

const double _loudnessOffset = -0.691; // BS.1770 channel-sum offset
const double _absoluteGateLufs = -70.0;
const double _relativeGateLu = 10.0;
const double _blockSeconds = 0.4;
const double _hopSeconds = 0.1;

Stream<double> _fileEnergies(PcmFile file, bool Function()? cancelled) async* {
  final pre = _preFilter(file.sampleRate.toDouble());
  final rlb = _rlbHighPass(file.sampleRate.toDouble());
  final size = (file.sampleRate * _blockSeconds).round();
  final hop = (file.sampleRate * _hopSeconds).round();
  final ring = Float64List(size);
  var sum = 0.0;
  var seen = 0;
  await for (final block in file.blocks(isCancelled: cancelled)) {
    for (final sample in block) {
      final y = rlb.process(pre.process(sample));
      final slot = seen % size;
      sum += y * y - ring[slot];
      ring[slot] = y * y;
      seen++;
      if (seen >= size && (seen - size) % hop == 0) yield math.max(0, sum / size);
    }
  }
  if (seen > 0 && seen < size) yield sum / seen;
}

double _log10(double x) => math.log(x) / math.ln10;

/// Mean-square of one 400 ms block -> block loudness in LUFS.
double _lufs(double meanSquare) =>
    meanSquare <= 0 ? double.negativeInfinity : _loudnessOffset + 10 * _log10(meanSquare);

/// 400 ms blocks, 75% overlap, K-weighted. Returns mean-square per block.
List<double> _blockMeanSquares(Float32List samples, int fs) {
  final n = samples.length;
  if (n == 0) return const [];

  final pre = _preFilter(fs.toDouble());
  final rlb = _rlbHighPass(fs.toDouble());
  final blockSize = (_blockSeconds * fs).round();

  if (n <= blockSize) {
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final y = rlb.process(pre.process(samples[i]));
      sum += y * y;
    }
    return [sum / n];
  }

  final hop = (_hopSeconds * fs).round();
  final nBlocks = (n - blockSize) ~/ hop + 1;
  final sums = Float64List(nBlocks);

  for (var i = 0; i < n; i++) {
    final y = rlb.process(pre.process(samples[i]));
    final sq = y * y;
    // Every sample belongs to up to 4 overlapping blocks.
    final first = ((i - blockSize + 1) / hop).ceil().clamp(0, nBlocks - 1).toInt();
    final last = (i ~/ hop).clamp(0, nBlocks - 1).toInt();
    for (var b = first; b <= last; b++) {
      sums[b] += sq;
    }
  }
  return List<double>.generate(nBlocks, (b) => sums[b] / blockSize);
}

/// Two-stage gating (absolute then relative) -> integrated loudness.
double _gatedLoudness(List<double> z) {
  if (z.isEmpty) return double.negativeInfinity;

  var absSum = 0.0;
  var absCount = 0;
  for (final zj in z) {
    if (_lufs(zj) > _absoluteGateLufs) {
      absSum += zj;
      absCount++;
    }
  }
  if (absCount == 0) return double.negativeInfinity;

  final relativeGate = _lufs(absSum / absCount) - _relativeGateLu;
  var sum = 0.0;
  var count = 0;
  for (final zj in z) {
    final lj = _lufs(zj);
    if (lj > _absoluteGateLufs && lj > relativeGate) {
      sum += zj;
      count++;
    }
  }
  return count == 0 ? double.negativeInfinity : _lufs(sum / count);
}

/// Direct Form I biquad.
class _Biquad {
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);

  final double b0, b1, b2, a1, a2;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;

  double process(double x) {
    final y = b0 * x + b1 * _x1 + b2 * _x2 - a1 * _y1 - a2 * _y2;
    _x2 = _x1;
    _x1 = x;
    _y2 = _y1;
    _y1 = y;
    return y;
  }
}

/// Stage 1: high-shelf pre-filter. Analog prototype params from BS.1770-4;
/// bilinear transform at [fs] gives the correct coefficients at any rate.
_Biquad _preFilter(double fs) {
  const f0 = 1681.974450955533;
  const gainDb = 3.999843853973347;
  const q = 0.7071752369554196;
  final k = math.tan(math.pi * f0 / fs);
  final vh = math.pow(10, gainDb / 20).toDouble();
  final vb = math.pow(vh, 0.4996667741545416).toDouble();
  final a0 = 1 + k / q + k * k;
  return _Biquad(
    (vh + vb * k / q + k * k) / a0,
    2 * (k * k - vh) / a0,
    (vh - vb * k / q + k * k) / a0,
    2 * (k * k - 1) / a0,
    (1 - k / q + k * k) / a0,
  );
}

/// Stage 2: RLB high-pass.
_Biquad _rlbHighPass(double fs) {
  const f0 = 38.13547087602444;
  const q = 0.5003270373238773;
  final k = math.tan(math.pi * f0 / fs);
  final a0 = 1 + k / q + k * k;
  return _Biquad(
    1.0,
    -2.0,
    1.0,
    2 * (k * k - 1) / a0,
    (1 - k / q + k * k) / a0,
  );
}

// --- True peak --------------------------------------------------------------

const int _tpHalfTaps = 8; // original samples each side
final List<List<double>> _tpCoef = _buildTruePeakCoef();

/// 4x-oversampled true-peak estimate in dBTP. [double.negativeInfinity] for
/// silence.
double truePeakDb(Float32List samples) {
  final peak = _truePeak(samples);
  return peak <= 0 ? double.negativeInfinity : 20 * _log10(peak);
}

/// ponytail: O(48n) windowed-sinc interpolation. Fine for clips (30 s -> ~23M
/// ops). Stretch to a polyphase FIR if multi-hour files ever go through here.
double _truePeak(Float32List x, {int start = 0, int? end}) {
  final n = x.length;
  final stop = end ?? n;
  if (n == 0) return 0;

  var peak = 0.0;
  for (var i = start; i < stop; i++) {
    final a = x[i].abs();
    if (a > peak) peak = a;
  }
  if (peak == 0) return 0;

  const half = _tpHalfTaps;
  const span = 2 * half;
  for (var p = 1; p < 4; p++) {
    final taps = _tpCoef[p];
    for (var m = start; m < stop; m++) {
      var acc = 0.0;
      for (var i = 0; i < span; i++) {
        final k = m + i - (half - 1);
        if (k >= 0 && k < n) acc += x[k] * taps[i];
      }
      final a = acc.abs();
      if (a > peak) peak = a;
    }
  }
  return peak;
}

/// Per-phase Hann-windowed sinc, unity DC gain. Phase 0 is the identity.
List<List<double>> _buildTruePeakCoef() {
  final phases = <List<double>>[];
  for (var p = 0; p < 4; p++) {
    final d = p / 4.0;
    final taps = <double>[];
    var sum = 0.0;
    for (var i = 0; i < 2 * _tpHalfTaps; i++) {
      final u = d - (i - (_tpHalfTaps - 1));
      final sinc = u == 0 ? 1.0 : math.sin(math.pi * u) / (math.pi * u);
      final w = 0.5 * (1 + math.cos(math.pi * u / _tpHalfTaps));
      final v = sinc * w;
      taps.add(v);
      sum += v;
    }
    for (var i = 0; i < taps.length; i++) {
      taps[i] /= sum;
    }
    phases.add(taps);
  }
  return phases;
}

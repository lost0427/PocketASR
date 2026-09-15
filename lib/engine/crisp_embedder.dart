/// Native CrispEmbed [Embedder] adapter (plan §2 / Phase 8).
///
/// Thin wrapper over `package:crispembed`'s synchronous FFI API. Constructing
/// one loads the native library and the GGUF model immediately; a missing
/// `.so`/`.dll` or an unreadable model throws [EmbedderUnavailableException]
/// rather than falling back to [DeterministicEmbedder]. This build ships no
/// `libcrispembed`, so construction currently fails loudly — which is the
/// point: semantic search must never fake meaning.
library;

import 'dart:typed_data';

import 'package:crispembed/crispembed.dart' as crisp;

import 'embedder.dart';

/// [Embedder] backed by the native `libcrispembed` / `crispembed.dll`.
class CrispEmbedder implements Embedder {
  /// Loads [modelPath] now. [threads] is the native CPU thread count (0 lets
  /// the library auto-detect); [libPath] overrides the platform default library
  /// location, for callers that stage the `.so`/`.dll` themselves.
  CrispEmbedder({required String modelPath, int threads = 0, String? libPath})
    : _model = _open(modelPath, threads: threads, libPath: libPath),
      id = 'crispembed:${_basename(modelPath)}' {
    dim = _probeDim(_model, modelPath);
  }

  final crisp.CrispEmbed _model;

  /// Model identity stored in the `embedding.model` column: the file name, so
  /// vectors from a different model file never mix.
  @override
  final String id;

  /// Vector length, read from the model's first encode. `CrispEmbed` exposes no
  /// `dim` getter, so a one-off probe is the only honest source.
  @override
  late final int dim;

  @override
  Float32List embed(String text) => _model.encode(text);

  @override
  Future<void> dispose() async {
    _model.dispose();
  }

  static crisp.CrispEmbed _open(
    String modelPath, {
    required int threads,
    String? libPath,
  }) {
    try {
      return crisp.CrispEmbed(modelPath, nThreads: threads, libPath: libPath);
    } catch (error) {
      throw EmbedderUnavailableException(
        'CrispEmbed native library failed to open/load "$modelPath": $error',
      );
    }
  }

  static int _probeDim(crisp.CrispEmbed model, String modelPath) {
    final probe = model.encode(' ');
    if (probe.isEmpty) {
      throw EmbedderUnavailableException(
        'CrispEmbed returned an empty vector for "$modelPath"; '
        'cannot determine the embedding dimension.',
      );
    }
    return probe.length;
  }

  static String _basename(String path) => path.split(RegExp(r'[\\/]')).last;
}

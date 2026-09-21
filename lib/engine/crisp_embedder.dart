/// Native CrispEmbed [Embedder] adapter (plan §2 / Phase 8).
///
/// Thin wrapper over `package:crispembed`'s synchronous FFI API. Because every
/// call here blocks the calling isolate, this class is constructed **only
/// inside the embedding worker isolate** (see embedding_worker.dart); the UI
/// thread talks to [WorkerEmbedder], a mailbox. Constructing one loads the
/// native library and the GGUF model immediately; a missing `.so`/`.dll` or an
/// unreadable model throws [EmbedderUnavailableException] rather than falling
/// back to [DeterministicEmbedder]. Android and Windows release builds stage
/// the native library from pinned source; unsupported or incomplete builds
/// still fail loudly so semantic search never fakes meaning.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:crispembed/crispembed.dart' as crisp;

import 'embedder.dart';

/// [Embedder] backed by the native `libcrispembed` / `crispembed.dll`.
///
/// Worker-isolate-only: do not construct on the root isolate (see class docs
/// and [WorkerEmbedder.crisp] for the sanctioned construction site).
class CrispEmbedder implements Embedder {
  /// Loads [modelPath] now. [threads] is the native CPU thread count; a
  /// non-positive value is **one** thread, not "auto": crispembed maps
  /// `n_threads <= 0` to 1 (crispembed.cpp, `ctx->n_threads = n_threads > 0 ?
  /// n_threads : 1;`), so every caller that wants more must say so.
  /// [libPath] overrides the platform default library
  /// location, for callers that stage the `.so`/`.dll` themselves.
  CrispEmbedder({
    required String modelPath,
    this.profile = EmbeddingModelProfile.metadata,
    int threads = 0,
    String? libPath,
  }) : _model = _open(modelPath, threads: threads, libPath: libPath),
       id = identityFor(modelPath) {
    try {
      dim = _probeDim(_model, modelPath);
      // Verified against crispembed 0.16.1 (the local package and pinned native
      // source): encode() applies only
      // the settable ctx prefix — documented as "empty string if none", and
      // the package's own example sets `query: ` manually to prefix outputs.
      // Model-declared query/passage prefixes are exposed as *read-only*
      // getters for the caller to apply, so encode() does not add them
      // automatically. The `_model.prefix` check makes a double-prefix
      // impossible if a future build starts pre-setting the ctx prefix on
      // load. Profiles with an explicit convention (Qwen3) override these
      // metadata prefixes in [embedQuery]/[embedDocument].
      if (_model.prefix.isEmpty) {
        _queryPrefix = _model.ctxQueryPrefix;
        _passagePrefix = _model.ctxPassagePrefix;
      } else {
        _queryPrefix = '';
        _passagePrefix = '';
      }
    } catch (error) {
      _model.dispose(); // the probe can fail after the native ctx was loaded
      if (error is EmbedderUnavailableException) rethrow;
      throw EmbedderUnavailableException(
        'CrispEmbed failed to initialize "$modelPath": $error',
      );
    }
  }

  final crisp.CrispEmbed _model;
  final EmbeddingModelProfile profile;
  late final String _queryPrefix;
  late final String _passagePrefix;

  /// Model identity stored in the `embedding.model` column: the full requested
  /// path plus file size — see [identityFor].
  @override
  final String id;

  /// Vector length, read from the model's first encode. `CrispEmbed` exposes no
  /// `dim` getter, so a one-off probe is the only honest source.
  @override
  late final int dim;

  @override
  Float32List embed(String text) => _model.encode(text);

  @override
  Float32List embedQuery(String text) =>
      _model.encode(profile.queryInput(text, metadataPrefix: _queryPrefix));

  @override
  Float32List embedDocument(String text) => _model.encode(
    profile.documentInput(text, metadataPrefix: _passagePrefix),
  );

  @override
  Future<void> dispose() async {
    _model.dispose();
  }

  /// A model identity that does not collide across different model files.
  ///
  /// The basename alone conflates `a/e5.gguf` and `b/e5.gguf`, and survives an
  /// in-place model swap, so vectors from different models would mix in one
  /// `embedding.model` bucket. The full path plus size separates both cases.
  /// Stated ceilings: a *name* (no path separators, which crispembed resolves
  /// to its own cache download) is tracked by that name only, and a same-size
  /// file at the same path is treated as the same model — content is not
  /// hashed, since hashing a multi-GB GGUF at startup is not worth it.
  static String identityFor(String modelPath) {
    try {
      final stat = File(modelPath).statSync();
      if (stat.type == FileSystemEntityType.notFound) {
        return 'crispembed:$modelPath';
      }
      return 'crispembed:$modelPath:${stat.size}';
    } on FileSystemException {
      return 'crispembed:$modelPath';
    }
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
}

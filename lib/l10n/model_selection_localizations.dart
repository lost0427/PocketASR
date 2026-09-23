import '../app/app_state.dart';
import 'app_localizations.dart';

/// Localized, user-actionable text for a model preflight failure.
extension ModelSelectionLocalizations on AppLocalizations {
  String messageForModelSelectionProblem(ModelSelectionProblem problem) =>
      switch (problem) {
        ModelSelectionProblem.missingWhisperDecoder => modelNeedsDecoder,
        ModelSelectionProblem.sherpaMnnCatalogBundleRequired =>
          modelNeedsVerifiedMnnBundle,
        ModelSelectionProblem.sherpaMnnTokensRequired => modelNeedsMnnTokens,
      };
}

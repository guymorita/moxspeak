import Foundation

class TokenContext {
  var futureVowel: Bool?
  var futureTo: Bool

  /// The word immediately *before* the one being transcribed. (MoxSpeak addition.)
  ///
  /// Everything else here is lookahead — the G2P walks the sentence backwards, so
  /// `futureVowel` and `futureTo` describe the token that follows. Resolving an English
  /// heteronym usually needs the other direction: "read" is /ɹɛd/ after "had" and /ɹid/
  /// after "will", and nothing about the word itself can tell you which.
  ///
  /// Set by the loop in EnglishG2P, which has both neighbours to hand.
  var previousWord: String?

  init(futureVowel: Bool? = nil, futureTo: Bool = false, previousWord: String? = nil) {
    self.futureVowel = futureVowel
    self.futureTo = futureTo
    self.previousWord = previousWord
  }
}

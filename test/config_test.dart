import 'package:flutter_test/flutter_test.dart';
import 'package:oyun_bilardo/oyun_bilardo.dart';

void main() {
  test('33 dilde ad, slogan, anlatım ve eğitim var', () {
    expect(bilardoConfig.gameId, 'oyun-bilardo');
    expect(bilardoConfig.title.length, 33);
    expect(bilardoConfig.tagline.length, 33);
    for (final s in bilardoConfig.tutorial) {
      expect(s.text.length, 33);
      expect(s.text.every((t) => t.trim().isNotEmpty), isTrue);
    }
  });
}

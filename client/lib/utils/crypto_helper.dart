import 'dart:convert';
import 'dart:math';
import 'package:encrypt/encrypt.dart' as enc;

/// CryptoHelper 提供端到端加密 (E2EE) 使用的对称加解密算法工具
class CryptoHelper {
  /// 生成随机 256 位 AES 密钥 (Base64Url 编码)
  static String generateAESKey() {
    final random = Random.secure();
    final values = List<int>.generate(32, (i) => random.nextInt(256));
    return base64Url.encode(values);
  }

  /// 使用 AES-CBC 对文本进行加密，返回 iv.ciphertext 格式密文
  static String encryptText(String text, String base64Key) {
    if (base64Key.isEmpty || text.isEmpty) return text;
    try {
      final keyBytes = base64Url.decode(base64Key);
      final key = enc.Key(keyBytes);
      final iv = enc.IV.fromSecureRandom(16);

      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      final encrypted = encrypter.encrypt(text, iv: iv);

      // 密文格式：[IV Base64Url].[Ciphertext Base64]
      return '${base64Url.encode(iv.bytes)}.${encrypted.base64}';
    } catch (e) {
      print('[ERROR] CryptoHelper encryptText error: $e');
      return text;
    }
  }

  /// 使用 AES-CBC 对 iv.ciphertext 格式的密文进行解密
  static String decryptText(String encryptedText, String base64Key) {
    if (base64Key.isEmpty || encryptedText.isEmpty) return encryptedText;
    try {
      final parts = encryptedText.split('.');
      if (parts.length != 2) {
        // 格式不匹配（可能为未加密的明文历史数据），直接返回原始文字
        return encryptedText;
      }

      final keyBytes = base64Url.decode(base64Key);
      final key = enc.Key(keyBytes);
      final ivBytes = base64Url.decode(parts[0]);
      final iv = enc.IV(ivBytes);

      final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc));
      return encrypter.decrypt64(parts[1], iv: iv);
    } catch (e) {
      print('[ERROR] CryptoHelper decryptText error: $e');
      // 解密失败（可能密钥不一致），降级返回密文以防崩溃
      return encryptedText;
    }
  }
}

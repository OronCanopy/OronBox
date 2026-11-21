import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:oronbox/src/core/errors/coded_error.dart';

import 'astrobox_resource_decryption.dart';

class AstroBoxResourceAccess {
  AstroBoxResourceAccess(this._dio);

  static const apiBase = 'https://astrobox-api.astralsight.space';
  final Dio _dio;

  Future<Map<String, AstroBoxPurchaseDevice>> purchaseInfo(
    String resourceId,
  ) async {
    try {
      final response = await _dio.post<Object?>(
        '$apiBase/resource/purchase_info',
        data: {'resourceId': resourceId},
      );
      final data = _object(response.data);
      if (data['resourceId'] != resourceId || data['devices'] is! List) {
        throw const FormatException('Invalid purchase information');
      }
      return {
        for (final row in data['devices'] as List)
          (row as Map)['deviceId'] as String: AstroBoxPurchaseDevice(
            deviceId: row['deviceId'] as String,
            fileName: row['fileName'] as String,
            version: row['version'] as String,
            isPaid: row['isPaid'] as bool,
          ),
      };
    } catch (_) {
      throw const AstroBoxResourceAccessError('astrobox_access_check_failed');
    }
  }

  Future<Uint8List?> decryptionKey({
    required String resourceId,
    required String deviceId,
    required String hash,
  }) async {
    try {
      final response = await _dio.post<Object?>(
        '$apiBase/resource/query_crypto_info',
        data: {'id': resourceId, 'deviceId': deviceId, 'hash': hash},
      );
      final data = _object(response.data);
      final payload = data['payload'];
      if (payload is! Map ||
          payload['hash'] != hash ||
          payload['key'] is! String) {
        throw const FormatException('Invalid encryption information');
      }
      return decodeAstroBoxResourceKey(payload['key'] as String);
    } on DioException catch (error) {
      if (_errorCode(error.response?.data) == 'file_not_found') return null;
      throw const AstroBoxResourceAccessError('astrobox_access_check_failed');
    } on AstroBoxResourceAccessError catch (error) {
      if (error.code == 'file_not_found') return null;
      throw const AstroBoxResourceAccessError('astrobox_access_check_failed');
    } catch (_) {
      throw const AstroBoxResourceAccessError('astrobox_access_check_failed');
    }
  }

  Map<String, Object?> _object(Object? value) {
    if (value is String) value = jsonDecode(value);
    if (value is! Map) throw const FormatException('Invalid AstroBox response');
    if (value['success'] == false) {
      throw AstroBoxResourceAccessError(
        _errorCode(value) ?? 'astrobox_access_check_failed',
      );
    }
    return (value['success'] == true ? value['data'] as Map : value)
        .cast<String, Object?>();
  }

  String? _errorCode(Object? value) {
    if (value is String) {
      try {
        return _errorCode(jsonDecode(value));
      } on FormatException {
        return value.trim();
      }
    }
    if (value is Map) {
      return (value['error'] ?? value['message'] ?? value['code'])?.toString();
    }
    return null;
  }
}

class AstroBoxPurchaseDevice {
  const AstroBoxPurchaseDevice({
    required this.deviceId,
    required this.fileName,
    required this.version,
    required this.isPaid,
  });

  final String deviceId;
  final String fileName;
  final String version;
  final bool isPaid;
}

class AstroBoxResourceAccessError implements CodedError {
  const AstroBoxResourceAccessError(this.code);

  @override
  final String code;
  @override
  String get message => code;
  @override
  Object? get details => null;
  @override
  String toString() => code;
}

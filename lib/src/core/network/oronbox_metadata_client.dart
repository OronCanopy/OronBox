import 'package:dio/dio.dart';
import 'package:oronbox/src/core/constants/oronbox_server.dart';

class OronBoxMetadataClient {
  OronBoxMetadataClient(this._dio);

  final Dio _dio;
  final _cache = <String, ({String etag, String body})>{};

  Future<String> get(String path) async {
    final cached = _cache.remove(path);
    if (cached != null) _cache[path] = cached;
    final response = await _dio.get<String>(
      '$oronBoxServerBaseUrl/api/v1/$path',
      options: Options(
        responseType: ResponseType.plain,
        headers: {if (cached != null) 'If-None-Match': cached.etag},
        validateStatus: (status) => status == 200 || status == 304,
      ),
    );
    if (response.statusCode == 304 && cached != null) return cached.body;
    final body = response.data;
    if (body == null || body.isEmpty) {
      throw const FormatException('OronBox metadata response is empty');
    }
    _cache.remove(path);
    final etag = response.headers.value('etag');
    if (etag != null && etag.isNotEmpty) {
      _cache[path] = (etag: etag, body: body);
      if (_cache.length > 64) _cache.remove(_cache.keys.first);
    }
    return body;
  }
}

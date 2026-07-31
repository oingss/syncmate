/// 协议错误（对应 docs/schemas/error_response.schema.json）。
library;

enum ApiErrorCode {
  forbidden,
  badRequest,
  notFound,
  invalidPath,
  conflict,
  ioError,
  rejected,
  timeout;

  String get wire => name.toUpperCase();

  static ApiErrorCode fromWire(String value) {
    for (final code in ApiErrorCode.values) {
      if (code.wire == value) return code;
    }
    return badRequest;
  }
}

class ApiException implements Exception {
  const ApiException(this.code, this.message);

  final ApiErrorCode code;
  final String message;

  @override
  String toString() => 'ApiException(${code.wire}): $message';
}

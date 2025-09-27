class ApiException implements Exception {
  final String message;
  const ApiException(this.message);

  @override
  String toString() => 'ApiException: $message';
}

class NotFoundException extends ApiException {
  const NotFoundException(super.message);

  @override
  String toString() => 'NotFoundException: $message';
}

class NetworkException extends ApiException {
  const NetworkException(super.message);

  @override
  String toString() => 'NetworkException: $message';
}

class ServerException extends ApiException {
  const ServerException(super.message);

  @override
  String toString() => 'ServerException: $message';
}

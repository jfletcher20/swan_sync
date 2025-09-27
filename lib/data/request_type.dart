// ignore_for_file: constant_identifier_names
enum RequestType {
  GET,
  GET_ALL,
  POST,
  PUT,
  DELETE;

  static RequestType? detectType({int? oid, required bool body, bool delete = false}) {
    if (body && oid == null) {
      return RequestType.POST;
    } else if (body && oid != null) {
      return RequestType.PUT;
    } else if (!body && oid != null) {
      return delete ? RequestType.DELETE : RequestType.GET;
    } else if (!body && oid == null) {
      return RequestType.GET_ALL;
    }
    return null;
  }
}

function handler(event) {
    var request = event.request;
    var headers = request.headers;
    var authString = "Basic ${authString}";

    if (
        typeof headers.authorization === "undefined" ||
        headers.authorization.value !== authString
    ) {
        return {
            statusCode: 401,
            statusDescription: "Unauthorized",
            headers: { "www-authenticate": { value: "Basic" } }
        };
    }

    // The credential has done its job at the edge. Do not forward it: the origin has no use for
    // the shared password, and a Basic header left in place would collide with any Authorization
    // scheme the application adopts later (e.g. Bearer).
    delete request.headers.authorization;

    return request;
}
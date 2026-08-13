import Foundation

struct WidgetHTTPResponse: Equatable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func serialized() -> Data {
        let reason = Self.reasonPhrase(for: statusCode)
        var text = "HTTP/1.1 \(statusCode) \(reason)\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            text += "\(name): \(value)\r\n"
        }
        text += "\r\n"

        var data = Data(text.utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }
}

enum WidgetHTTP {
    static let maximumRequestBytes = 8 * 1_024

    static func respond(
        request: Data,
        expectedToken: String,
        payload: Data
    ) -> WidgetHTTPResponse {
        guard request.count <= maximumRequestBytes,
              let requestText = String(data: request, encoding: .utf8),
              let headerEnd = requestText.range(of: "\r\n\r\n") else {
            return error(statusCode: 400, name: "bad_request")
        }

        let headerText = String(requestText[..<headerEnd.lowerBound])
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return error(statusCode: 400, name: "bad_request")
        }
        let requestParts = requestLine.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        guard requestParts.count == 3,
              !requestParts.contains(where: { $0.isEmpty }),
              requestParts[2] == "HTTP/1.1" else {
            return error(statusCode: 400, name: "bad_request")
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else {
                return error(statusCode: 400, name: "bad_request")
            }
            let name = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return error(statusCode: 400, name: "bad_request")
            }
            headers[name, default: []].append(value)
        }

        let authorizationValues = headers["authorization"] ?? []
        guard authorizationValues.count <= 1 else {
            return error(statusCode: 400, name: "bad_request")
        }

        let method = String(requestParts[0])
        let path = String(requestParts[1])
        guard method == "GET" else {
            return response(
                statusCode: 405,
                body: errorBody("method_not_allowed"),
                additionalHeaders: ["Allow": "GET"]
            )
        }
        guard path == "/v1/widget" else {
            return error(statusCode: 404, name: "not_found")
        }

        guard let authorization = authorizationValues.first,
              authorization.hasPrefix("Bearer ") else {
            return unauthorized()
        }
        let suppliedToken = String(authorization.dropFirst("Bearer ".count))
        guard !suppliedToken.isEmpty,
              WidgetToken.securelyEquals(suppliedToken, expectedToken) else {
            return unauthorized()
        }

        return response(statusCode: 200, body: payload)
    }

    private static func unauthorized() -> WidgetHTTPResponse {
        response(
            statusCode: 401,
            body: errorBody("unauthorized"),
            additionalHeaders: ["WWW-Authenticate": "Bearer"]
        )
    }

    private static func error(statusCode: Int, name: String) -> WidgetHTTPResponse {
        response(statusCode: statusCode, body: errorBody(name))
    }

    private static func errorBody(_ name: String) -> Data {
        Data(#"{"error":"\#(name)"}"#.utf8)
    }

    private static func response(
        statusCode: Int,
        body: Data,
        additionalHeaders: [String: String] = [:]
    ) -> WidgetHTTPResponse {
        var headers = additionalHeaders
        headers["Connection"] = "close"
        headers["Content-Length"] = String(body.count)
        headers["Content-Type"] = "application/json; charset=utf-8"
        return WidgetHTTPResponse(statusCode: statusCode, headers: headers, body: body)
    }
}

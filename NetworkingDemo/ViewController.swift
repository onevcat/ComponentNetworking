//
//  ViewController.swift
//  NetworkingDemo
//
//  Created by Wang Wei on 2019/04/04.
//  Copyright © 2019 OneV's Den. All rights reserved.
//

import UIKit

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.

        postWithClientRequest()
    }

    func get() {
        let request = URLRequest(url: URL(string: "https://httpbin.org/get")!)
        let task = URLSession.shared.dataTask(with: request) {

            (data, response, error) in

            guard let data = data else { return }
            let json = try? JSONSerialization.jsonObject(with: data, options: [])
            guard let dic = json as? [String: Any] else { return }

            print(dic["url"] as! String)
        }
        task.resume()
    }

    func post() {
        var request = URLRequest(url: URL(string: "https://httpbin.org/post")!)
        request.httpMethod = "POST"
        request.httpBody = "foo=bar".data(using: .utf8)

        let task = URLSession.shared.dataTask(with: request) {

            (data, response, error) in

            guard let data = data else { return }
            let json = try? JSONSerialization.jsonObject(with: data, options: [])
            guard let dic = json as? [String: Any] else { return }

            print((dic["form"] as! [String: Any])["foo"] as! String)
        }
        task.resume()
    }

    struct HTTPBinPostResponse: Codable {
        struct Form: Codable { let foo: String }
        let form: Form
    }

    struct HTTPBinPostRequest: Request {

        typealias Response = HTTPBinPostResponse

        let url = URL(string: "https://httpbin.org/post")!
        let method = HTTPMethod.POST
        let contentType = ContentType.urlForm

        var parameters: [String : Any] {
            return ["foo": foo]
        }

        let foo: String
    }

    func postWithClient() {
        let client = HTTPClient(session: .shared)
        let request = HTTPRequest(
            url: URL(string: "https://httpbin.org/post")!, method: "POST", parameters: ["foo": "bar"], headers: ["Content-Type": "application/x-www-form-urlencoded"])
        client.send(request) { (res: Result<HTTPBinPostResponse, Error>) in
            switch res {
            case .success(let value): print(value.form.foo)
            case .failure(let error): print(error)
            }
        }
    }

    func postWithClientRequest() {
        let client = HTTPClient(session: .shared)
        let request = HTTPBinPostRequest(foo: "bar")
        client.send(request) { res in
            switch res {
            case .success(let value): print(value.form.foo)
            case .failure(let error): print(error)
            }
        }
    }
}

enum ResponseError: Error {
    case nilData
    case nonHTTPResponse
    case tokenError
    case apiError(error: APIError, statusCode: Int)
}

struct APIError: Decodable {
    let code: Int
    let reason: String
}


struct RefreshTokenRequest: Request {

    struct Response: Decodable {
        let token: String
    }

    let url = URL(string: "someurl")!
    let method: HTTPMethod = .POST
    let contentType: ContentType = .json

    var parameters: [String : Any] {
        return ["refreshToken": refreshToken]
    }

    let refreshToken: String

}

class IndicatorManager {
    static var currentCount = 0
    static func increase() {
        currentCount += 1
        if currentCount >= 0 {
            UIApplication.shared
                .isNetworkActivityIndicatorVisible = true
        }
    }
    static func decrease() {
        currentCount = max(0, currentCount - 1)
        if currentCount == 0 {
            UIApplication.shared
                .isNetworkActivityIndicatorVisible = false
        }
    }
}

struct HTTPClient {

    let session: URLSession
    init(session: URLSession) {
        self.session = session
    }

    func send<T: Codable>(
        _ request: HTTPRequest,
        handler: @escaping (Result<T, Error>) -> Void)
    {
        let urlRequest = request.buildRequest()

        let task = session.dataTask(with: urlRequest) {
            data, response, error in

            if let error = error {
                handler(.failure(error))
                return
            }

            guard let data = data else {
                handler(.failure(ResponseError.nilData))
                return
            }

            guard let response = response as? HTTPURLResponse else {
                handler(.failure(ResponseError.nonHTTPResponse))
                return
            }

            if response.statusCode >= 300 {
                do {
                    let error = try decoder.decode(APIError.self, from: data)
                    if response.statusCode == 403 && error.code == 999 {
                        let freshTokenRequest = RefreshTokenRequest(refreshToken: "token123")
                        self.send(freshTokenRequest) { result in
                            switch result {
                            case .success(let token):
                                // keyChain.saveToken(result)
                                // Send current request again.
                                self.send(request, handler: handler)
                            case .failure:
                                handler(.failure(ResponseError.tokenError))
                            }
                        }
                        return
                    } else {
                        handler(.failure(
                            ResponseError.apiError(
                                error: error,
                                statusCode: response.statusCode)
                            )
                        )
                    }
                } catch {
                    handler(.failure(error))
                }
            }

            do {
                let realData = data.isEmpty ? "{}".data(using: .utf8)! : data
                let value = try decoder.decode(T.self, from: realData)
                handler(.success(value))
            } catch {
                handler(.failure(error))
            }
        }
        task.resume()
    }

    func send<Req: Request>(
        _ request: Req,
        decisions: [Decision]? = nil,
        handler: @escaping (Result<Req.Response, Error>) -> Void)
    {
        let urlRequest: URLRequest
        do {
            urlRequest = try request.buildRequest()
        } catch {
            handler(.failure(error))
            return
        }

        let task = session.dataTask(with: urlRequest) {
            data, response, error in

            guard let data = data else {
                handler(.failure(error ?? ResponseError.nilData))
                return
            }

            guard let response = response as? HTTPURLResponse else {
                handler(.failure(ResponseError.nonHTTPResponse))
                return
            }

            self.handleDecision(request, data: data, response: response, decisions: decisions ?? request.decisions, handler: handler)
        }
        task.resume()
    }

    func handleDecision<Req: Request>(_ request: Req, data: Data, response: HTTPURLResponse, decisions: [Decision], handler: @escaping (Result<Req.Response, Error>) -> Void) {
        guard !decisions.isEmpty else { fatalError("No decision left but did not reach a stop.") }

        var decisions = decisions
        let current = decisions.removeFirst()
        if current.shouldApply(request: request, data: data, response: response) {
            current.apply(request: request, data: data, response: response) { action in
                switch action {
                case .continueWith(let data, let response):
                    self.handleDecision(request, data: data, response: response, decisions: decisions, handler: handler)
                case .restartWith(let decisions):
                    self.send(request, decisions: decisions, handler: handler)
                case .errored(let error):
                    handler(.failure(error))
                case .done(let value):
                    handler(.success(value))
                }
            }
        } else {
            handleDecision(request, data: data, response: response, decisions: decisions, handler: handler)
        }
    }

}

enum HTTPMethod: String {
    case GET
    case POST

    var adapter: AnyAdapter {
        return AnyAdapter { req in
            var req = req
            req.httpMethod = self.rawValue
            return req
        }
    }
}

enum ContentType: String {
    case json = "application/json"
    case urlForm = "application/x-www-form-urlencoded; charset=utf-8"

    var headerAdapter: AnyAdapter {
        return AnyAdapter { req in
            var req = req
            req.setValue(self.rawValue, forHTTPHeaderField: "Content-Type")
            return req
        }
    }

    func dataAdapter(for data: [String: Any]) -> RequestAdapter {
        switch self {
        case .json: return JSONRequestDataAdapter(data: data)
        case .urlForm: return URLFormRequestDataAdapter(data: data)
        }
    }
}

protocol Request {

    associatedtype Response: Decodable

    var url: URL { get }
    var method: HTTPMethod { get }
    var parameters: [String: Any] { get }
    var contentType: ContentType { get }

    var adapters: [RequestAdapter] { get }
    var decisions: [Decision] { get }
}

extension Request {

    var adapters: [RequestAdapter] {
        return [
            method.adapter,
            RequestContentAdapter(method: method, contentType: contentType, content: parameters)
        ]
    }

    var decisions: [Decision] { return [
        RefreshTokenDecision(),
        RetryDecision(leftCount: 2),
        BadResponseStatusCodeDecision(),
        DataMappingDecision(condition: { $0.isEmpty }) { _ in
            return "{}".data(using: .utf8)!
        },
        ParseResultDecision()
        ]
    }

    func buildRequest() throws -> URLRequest {
        let request = URLRequest(url: url)
        return try adapters.reduce(request) { try $1.adapted($0) }
    }
}

struct HTTPRequest {

    let url: URL
    let method: String
    let parameters: [String: Any]
    let headers: [String: String]

    func buildRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method

        request.allHTTPHeaderFields = headers

        if method == "GET" {
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false)!
            components.queryItems = parameters.map {
                URLQueryItem(name: $0.key, value: $0.value as? String)
            }
            request.url = components.url
        } else {
            if headers["Content-Type"] == "application/json" {
                request.httpBody = try? JSONSerialization
                    .data(withJSONObject: parameters, options: [])
            } else if headers["Content-Type"] == "application/x-www-form-urlencoded" {
                request.httpBody = parameters
                    .map { "\($0.key)=\($0.value)" }
                    .joined(separator: "&")
                    .data(using: .utf8)
            } else {
                //...
            }
        }

        return request
    }
}

let decoder = JSONDecoder()

struct HTTPResponse<T: Codable> {
    let value: T?
    let response: HTTPURLResponse?
    let error: Error?

    init(data: Data?, response: URLResponse?, error: Error?) throws {
        self.value = try data.map { try decoder.decode(T.self, from: $0) }
        self.response = response as? HTTPURLResponse
        self.error = error
    }
}

protocol RequestAdapter {
    func adapted(_ request: URLRequest) throws -> URLRequest
}

struct AnyAdapter: RequestAdapter {
    let block: (URLRequest) throws -> URLRequest
    func adapted(_ request: URLRequest) throws -> URLRequest {
        return try block(request)
    }
}

struct RequestContentAdapter: RequestAdapter {

    let method: HTTPMethod
    let contentType: ContentType
    let content: [String: Any]

    func adapted(_ request: URLRequest) throws -> URLRequest {
        switch method {
        case .GET:
            return try URLQueryDataAdapter(data: content).adapted(request)
        case .POST:
            let headerAdapter = contentType.headerAdapter
            let dataAdapter = contentType.dataAdapter(for: content)
            let req = try headerAdapter.adapted(request)
            return try dataAdapter.adapted(req)
        }
    }
}

struct URLQueryDataAdapter: RequestAdapter {
    let data: [String: Any]
    func adapted(_ request: URLRequest) throws -> URLRequest {
        fatalError("Not implemented yet.")
    }
}

struct JSONRequestDataAdapter: RequestAdapter {
    let data: [String: Any]
    func adapted(_ request: URLRequest) throws -> URLRequest {
        var request = request
        request.httpBody = try JSONSerialization.data(withJSONObject: data, options: [])
        return request
    }
}

struct URLFormRequestDataAdapter: RequestAdapter {
    let data: [String: Any]
    func adapted(_ request: URLRequest) throws -> URLRequest {
        var request = request
        request.httpBody =
            data.map { "\($0.key)=\($0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)
        return request
    }
}

protocol Decision {
    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool
    func apply<Req: Request>(
        request: Req,
        data: Data,
        response: HTTPURLResponse,
        done closure: @escaping (DecisionAction<Req>) -> Void)
}

enum DecisionAction<Req: Request> {
    case continueWith(Data, HTTPURLResponse)
    case restartWith([Decision])
    case errored(Error)
    case done(Req.Response)
}

struct DataMappingDecision: Decision {

    let condition: (Data) -> Bool
    let transform: (Data) -> Data

    init(condition: @escaping ((Data) -> Bool), transform: @escaping (Data) -> Data) {
        self.transform = transform
        self.condition = condition
    }

    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool {
        return condition(data)
    }

    func apply<Req: Request>(
        request: Req,
        data: Data, response: HTTPURLResponse,
        done closure: @escaping (DecisionAction<Req>) -> Void)
    {
        closure(.continueWith(transform(data), response))
    }
}

let client = HTTPClient(session: .shared)

struct RefreshTokenDecision: Decision {

    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool {
        return response.statusCode == 403
    }

    func apply<Req: Request>(
        request: Req,
        data: Data,
        response: HTTPURLResponse,
        done closure: @escaping (DecisionAction<Req>) -> Void)
    {
        let refreshTokenRequest = RefreshTokenRequest(refreshToken: "abc123")
        client.send(refreshTokenRequest) { result in
            switch result {
            case .success(_):
                let decisionsWithoutRefresh = request.decisions.removing(self)
                closure(.restartWith(decisionsWithoutRefresh))
            case .failure(let error): closure(.errored(error))
            }
        }
    }
}

struct ParseResultDecision: Decision {
    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool {
        return true
    }

    func apply<Req: Request>(
        request: Req,
        data: Data,
        response: HTTPURLResponse,
        done closure: @escaping (DecisionAction<Req>) -> Void)
    {
        do {
            let value = try decoder.decode(Req.Response.self, from: data)
            closure(.done(value))
        } catch {
            closure(.errored(error))
        }
    }
}

struct RetryDecision: Decision {
    let leftCount: Int
    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool {
        let isStatusCodeValid = (200..<300).contains(response.statusCode)
        return !isStatusCodeValid && leftCount > 0
    }

    func apply<Req: Request>(
        request: Req,
        data: Data,
        response: HTTPURLResponse,
        done closure: @escaping (DecisionAction<Req>) -> Void)
    {
        let retryDecision = RetryDecision(leftCount: leftCount - 1)
        let newDecisions = request.decisions.replacing(self, with: retryDecision)
        closure(.restartWith(newDecisions))
    }
}

struct BadResponseStatusCodeDecision: Decision {
    func shouldApply<Req: Request>(request: Req, data: Data, response: HTTPURLResponse) -> Bool {
        return !(200..<300).contains(response.statusCode)
    }

    func apply<Req: Request>(
        request: Req,
        data: Data,
        response: HTTPURLResponse,
        done closure: @escaping (DecisionAction<Req>) -> Void)
    {
        do {
            let value = try decoder.decode(APIError.self, from: data)
            closure(.errored(ResponseError.apiError(error: value, statusCode: response.statusCode)))
        } catch {
            closure(.errored(error))
        }
    }
}

extension Array where Element == Decision {
    func removing(_ item: Decision) -> Array {
        print("Not implemented yet.")
        return self
    }

    func replacing(_ item: Decision, with: Decision?) -> Array {
        print("Not implemented yet.")
        return self
    }
}

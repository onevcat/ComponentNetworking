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

        IndicatorManager.increase()
        let task = session.dataTask(with: urlRequest) {
            data, response, error in

//            DispatchQueue.main.async {
//                IndicatorManager.decrease()
//            }

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
        handler: @escaping (Result<Req.Response, Error>) -> Void)
    {
        let urlRequest = request.buildRequest()
        let task = session.dataTask(with: urlRequest) {
            data, response, error in

            guard let data = data else {
                handler(.failure(error ?? ResponseError.nilData))
                return
            }

            do {
                let value = try decoder.decode(Req.Response.self, from: data)
                handler(.success(value))
            } catch {
                handler(.failure(error))
            }
        }
        task.resume()
    }
}

enum HTTPMethod: String {
    case GET
    case POST
}

enum ContentType: String {
    case json = "application/json"
    case urlForm = "application/x-www-form-urlencoded; charset=utf-8"
}

protocol Request {

    associatedtype Response: Decodable

    var url: URL { get }
    var method: HTTPMethod { get }
    var parameters: [String: Any] { get }
    var contentType: ContentType { get }
}

extension Request {
    func buildRequest() -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue

        if method == .GET {
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false)!
            components.queryItems = parameters.map {
                URLQueryItem(name: $0.key, value: $0.value as? String)
            }
            request.url = components.url
        } else {
            if contentType.rawValue.contains("application/json") {
                request.httpBody = try? JSONSerialization
                    .data(withJSONObject: parameters, options: [])
            } else if contentType.rawValue.contains("application/x-www-form-urlencoded") {
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


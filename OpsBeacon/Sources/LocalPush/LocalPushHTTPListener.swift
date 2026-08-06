@preconcurrency import NIOCore
@preconcurrency import NIOFoundationCompat
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix
import Foundation

public enum LocalPushHTTPListenerError: Error, LocalizedError {
    case invalidPort
    case listenerAlreadyRunning

    public var errorDescription: String? {
        switch self {
        case .invalidPort: "The Local Push listener port must be between 1024 and 65535."
        case .listenerAlreadyRunning: "The Local Push listener is already running."
        }
    }
}

/// One dual-stack HTTP/1.1 listener. It deliberately binds only loopback addresses.
public actor LocalPushHTTPListener {
    private let registry: PushRouteRegistry
    private let admission: PushConnectionAdmission
    private var group: MultiThreadedEventLoopGroup?
    private var channels: [any Channel] = []

    public init(registry: PushRouteRegistry) {
        self.registry = registry
        self.admission = PushConnectionAdmission()
    }

    public func start(port: Int) async throws {
        guard (1_024...65_535).contains(port) else { throw LocalPushHTTPListenerError.invalidPort }
        guard group == nil else { throw LocalPushHTTPListenerError.listenerAlreadyRunning }
        let newGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let ipv4 = try await bind(host: "127.0.0.1", port: port, group: newGroup)
            do {
                let ipv6 = try await bind(host: "::1", port: port, group: newGroup)
                group = newGroup
                channels = [ipv4, ipv6]
            } catch {
                try? await close(ipv4)
                try? await shutdown(newGroup)
                throw error
            }
        } catch {
            try? await shutdown(newGroup)
            throw error
        }
    }

    public func stop() async {
        let active = channels
        channels.removeAll()
        let activeGroup = group
        group = nil
        for channel in active { try? await close(channel) }
        if let activeGroup { try? await shutdown(activeGroup) }
    }

    private func bind(host: String, port: Int, group: MultiThreadedEventLoopGroup) async throws -> any Channel {
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .childChannelInitializer { [registry, admission] channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                    channel.pipeline.addHandler(HTTPConnectionHandler(registry: registry, admission: admission))
                }
            }
        return try await bootstrap.bind(host: host, port: port).get()
    }

    private func close(_ channel: any Channel) async throws {
        try await channel.close().get()
    }

    private func shutdown(_ group: MultiThreadedEventLoopGroup) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            group.shutdownGracefully { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}

private final class HTTPConnectionHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart

    private let registry: PushRouteRegistry
    private let admission: PushConnectionAdmission
    private var admitted = false
    private var responsePending = false
    private var incompleteRequestDeadline: Scheduled<Void>?
    private var requestHead: HTTPRequestHead?
    private var requestBody = Data()
    private var bodyTooLarge = false

    init(registry: PushRouteRegistry, admission: PushConnectionAdmission) {
        self.registry = registry
        self.admission = admission
    }

    func channelActive(context: ChannelHandlerContext) {
        guard admission.acquire() else {
            send(.json(503, ["error": "service unavailable"], headers: ["Retry-After": "1"]), on: context, version: .http1_1)
            return
        }
        admitted = true
        let loopBoundContext = context.loopBound
        incompleteRequestDeadline = context.eventLoop.scheduleTask(in: .seconds(5)) { [weak self, loopBoundContext] in
            guard let self, !self.responsePending else { return }
            loopBoundContext.value.close(promise: nil)
        }
        context.channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { [weak self, loopBoundContext] result in
            guard case .success = result else {
                loopBoundContext.value.close(promise: nil)
                return
            }
            guard self?.admitted == true else { return }
            loopBoundContext.value.read()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        incompleteRequestDeadline?.cancel()
        incompleteRequestDeadline = nil
        if admitted {
            admitted = false
            admission.release()
        }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard admitted, !responsePending else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            guard headerByteCount(of: head) <= PushRouteRegistry.maximumHeaderBytes else {
                responsePending = true
                incompleteRequestDeadline?.cancel()
                incompleteRequestDeadline = nil
                send(.json(431, ["error": "headers too large"]), on: context, version: head.version)
                return
            }
            requestHead = head
            requestBody.removeAll(keepingCapacity: true)
            bodyTooLarge = false
        case .body(var buffer):
            if requestBody.count + buffer.readableBytes > PushSignalDecoder.maximumBodyBytes {
                bodyTooLarge = true
            } else if let bytes = buffer.readData(length: buffer.readableBytes) {
                requestBody.append(bytes)
            }
        case .end:
            guard let head = requestHead else { return }
            responsePending = true
            incompleteRequestDeadline?.cancel()
            incompleteRequestDeadline = nil
            let headers = Dictionary(head.headers.map { ($0.name, $0.value) }, uniquingKeysWith: { _, later in later })
            let request = HTTPRequest(method: head.method.rawValue, target: head.uri, headers: headers, body: requestBody)
            let registry = registry
            let bodyWasTooLarge = bodyTooLarge
            let writer = HTTPResponseWriter(context: context, version: head.version)
            context.eventLoop.makeFutureWithTask {
                if bodyWasTooLarge { return HTTPResponse.json(413, ["error": "body too large"]) }
                return await registry.handle(request)
            }.whenComplete { result in
                switch result {
                case .success(let response): writer.send(response)
                case .failure: writer.send(.json(503, ["error": "service unavailable"], headers: ["Retry-After": "1"]))
                }
            }
        }
    }

    private func headerByteCount(of head: HTTPRequestHead) -> Int {
        head.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count + 4 }
    }

    private func send(_ response: HTTPResponse, on context: ChannelHandlerContext, version: HTTPVersion) {
        HTTPResponseWriter(context: context, version: version).send(response)
    }
}

private final class HTTPResponseWriter: @unchecked Sendable {
    private let context: ChannelHandlerContext
    private let version: HTTPVersion

    init(context: ChannelHandlerContext, version: HTTPVersion) {
        self.context = context
        self.version = version
    }

    func send(_ response: HTTPResponse) {
        context.eventLoop.execute { [self] in
            var headers = HTTPHeaders()
            response.headers.forEach { headers.add(name: $0.key, value: $0.value) }
            headers.replaceOrAdd(name: "Connection", value: "close")
            let responseHead = HTTPResponseHead(version: version, status: .init(statusCode: response.status), headers: headers)
            context.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            var buffer = context.channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            let promise = context.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete { [self] _ in context.close(promise: nil) }
            context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: promise)
        }
    }
}

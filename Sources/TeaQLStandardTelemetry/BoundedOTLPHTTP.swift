import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Per-exporter session with bounded streaming buffers and no redirect or
/// credential feedback into a customer's transport/SDK configuration.
final class BoundedOTLPHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  enum Result: Sendable { case received(Data), invalidResponse, failed }
  final class Reply: @unchecked Sendable {
    let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result?
    var value: Result { lock.withLock { result ?? .failed } }
    func finish(_ result: Result) {
      let signal = lock.withLock { if self.result != nil { return false }; self.result = result; return true }
      if signal { completed.signal() }
    }
  }
  private final class Exchange {
    let reply: Reply
    var body = Data()
    var accepted = false
    var hasContentType = false
    init(_ reply: Reply) { self.reply = reply }
  }
  private let lock = NSLock()
  private var pending: [Int: Exchange] = [:]
  private var closed = false
  private var session: URLSession!
  var activeRequests: Int { lock.withLock { pending.count } }
  var isClosed: Bool { lock.withLock { closed } }
  init(configuration: URLSessionConfiguration) {
    super.init()
    let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }
  func send(_ request: URLRequest, timeout: TimeInterval) -> Result {
    let reply = Reply()
    let task = lock.withLock { () -> URLSessionDataTask? in
      guard !closed else { return nil }
      let task = session.dataTask(with: request)
      pending[task.taskIdentifier] = Exchange(reply)
      return task
    }
    guard let task else { return .failed }
    task.resume()
    if reply.completed.wait(timeout: .now() + timeout) == .timedOut {
      let exchange = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
      exchange?.reply.finish(.failed); task.cancel()
      return .failed
    }
    return reply.value
  }
  func shutdown() {
    let replies = lock.withLock { () -> [Reply] in
      closed = true; let replies = pending.values.map(\.reply); pending.removeAll(); return replies
    }
    replies.forEach { $0.finish(.failed) }; session.invalidateAndCancel()
  }
  private func finish(_ task: URLSessionTask, _ result: Result) {
    lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }?.reply.finish(result)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      finish(dataTask, .failed); completionHandler(.cancel); return
    }
    let type = http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard (type == nil || type == "application/x-protobuf"),
      response.expectedContentLength <= Int64(OTLPAcknowledgement.maximumBytes) else {
      finish(dataTask, .invalidResponse); completionHandler(.cancel); return
    }
    let exists = lock.withLock { () -> Bool in
      guard let exchange = pending[dataTask.taskIdentifier] else { return false }
      exchange.accepted = true; exchange.hasContentType = type != nil; return true
    }
    completionHandler(exists ? .allow : .cancel)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let rejected = lock.withLock { () -> Bool in
      guard let exchange = pending[dataTask.taskIdentifier] else { return true }
      guard data.count <= OTLPAcknowledgement.maximumBytes - exchange.body.count else { return true }
      exchange.body.append(data); return false
    }
    if rejected { finish(dataTask, .invalidResponse); dataTask.cancel() }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    let exchange = lock.withLock { pending.removeValue(forKey: task.taskIdentifier) }
    guard let exchange else { return }
    if error == nil && exchange.accepted && !exchange.hasContentType && !exchange.body.isEmpty {
      exchange.reply.finish(.invalidResponse); return
    }
    exchange.reply.finish(error == nil && exchange.accepted ? .received(exchange.body) : .failed)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

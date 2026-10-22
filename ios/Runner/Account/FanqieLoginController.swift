import UIKit
import WebKit

/// The official page owns credentials and verification. No script/message
/// bridge reads page inputs, document cookies, or verification answers.
final class FanqieLoginController: UIViewController, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    var onCancel: (() -> Void)?
    var onRead: (() -> Void)?
    private let webView: WKWebView
    private let hint = UILabel()
    private let eink: Bool

    init(dataStore: WKWebsiteDataStore, dark: Bool?, eink: Bool) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.eink = eink
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = eink ? .light : dark.map { $0 ? .dark : .light } ?? .unspecified
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "番茄官方登录"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "返回", style: .plain, target: self, action: #selector(cancel))
        view.backgroundColor = eink ? .white : .systemBackground
        hint.text = "登录状态会在本机保留。登录与人机验证请在官方页面内完成，可双指缩放。"
        hint.numberOfLines = 0
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = eink ? .black : .secondaryLabel
        hint.adjustsFontForContentSizeCategory = true
        let read = UIButton(type: .system)
        read.setTitle("完成登录，读取书架", for: .normal)
        read.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        read.titleLabel?.adjustsFontForContentSizeCategory = true
        read.addTarget(self, action: #selector(readCookies), for: .touchUpInside)
        read.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        read.tintColor = eink ? .black : .systemRed
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        let stack = UIStackView(arrangedSubviews: [hint, webView, read])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
        webView.load(URLRequest(url: URL(string: "https://fanqienovel.com/main/writer/login")!))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true || navigationController?.presentingViewController == nil {
            onCancel?()
        }
    }

    func invalidSession() { hint.text = "请先完成官方登录和验证，再点击下方按钮。" }
    func stop() { webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil }
    @objc private func cancel() { onCancel?() }
    @objc private func readCookies() { onRead?() }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onCancel?() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, AccountCookiePolicy.allows(url) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url, AccountCookiePolicy.allows(url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Do not log raw URLs/errors: upstream redirects may carry credentials.
        hint.text = "官方页面安全连接或加载失败，请返回后重试。"
    }
}

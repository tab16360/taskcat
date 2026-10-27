import Foundation

enum WeChatEnvironment {
    // A shell-launched app inherits all_proxy=socks5://…; httpx then needs the optional
    // socksio package and the worker exits with ImportError. HTTP(S) proxies still apply.
    static func worker(_ inherited:[String:String])->[String:String] {
        inherited.filter {key,value in
            !(key.lowercased() == "all_proxy" && value.lowercased().hasPrefix("socks"))
        }
    }
}

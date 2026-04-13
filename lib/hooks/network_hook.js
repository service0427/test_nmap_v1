/* 
   Network Hook (V3 Refactored)
   - Exclusively handles Certificate Pinning & SSL Bypass.
   - Bypasses SSL Pinning (Native + OkHttp3 + TrustManager + SSLContext + Chromium).
*/

console.log("[*] Network Hook Script Loaded (Pure SSL Bypass)");

function hook_native_ssl() {
    var modules = Process.enumerateModules();
    modules.forEach(function (m) {
        var name = m.name.toLowerCase();
        if (name === "libssl.so" || name === "libboringssl.so") {
            try {
                var exports = m.enumerateExports();
                exports.forEach(function (exp) {
                    var n = exp.name;
                    if (n.indexOf("SSL_CTX_set_custom_verify") !== -1 || n.indexOf("SSL_set_custom_verify") !== -1 || n.indexOf("SSL_set_verify") !== -1) {
                        try {
                            Interceptor.attach(exp.address, { onEnter: function (args) { args[1] = ptr(0); } });
                        } catch (e) { }
                    }
                    if (n === "SSL_get_verify_result") {
                        try {
                            Interceptor.replace(exp.address, new NativeCallback(function (ssl) { return 0; }, 'long', ['pointer']));
                        } catch (e) { }
                    }
                });
            } catch (e) { }
        }
    });
}

function hook_java_all() {
    if (!Java.available) return;

    Java.perform(function () {
        // --- 1. TrustManager Implementation (The Core Bypass) ---
        var X509TrustManager = Java.use('javax.net.ssl.X509TrustManager');
        var SSLContext = Java.use('javax.net.ssl.SSLContext');

        var TrustManager = null;
        try {
            TrustManager = Java.registerClass({
                name: 'com.example.TrustManager',
                implements: [X509TrustManager],
                methods: {
                    checkClientTrusted: function (chain, authType) { },
                    checkServerTrusted: function (chain, authType) { },
                    getAcceptedIssuers: function () { return []; }
                }
            });
        } catch (e) {
            console.log("[-] Java.registerClass failed (Cache dir not ready). Proceeding without custom TrustManager array.");
        }

        try {
            var TrustManagerImpl = Java.use('com.android.org.conscrypt.TrustManagerImpl');
            TrustManagerImpl.verifyChain.implementation = function (untrustedChain, trustAnchorChain, host, clientAuth, ocspData, tlsSctData) {
                return untrustedChain;
            };
        } catch (e) { }

        // --- 2. SSLContext Hook ---
        try {
            if (TrustManager) {
                var TrustManagers = [TrustManager.$new()];
                var SSLContext_init = SSLContext.init.overload('[Ljavax.net.ssl.KeyManager;', '[Ljavax.net.ssl.TrustManager;', 'java.security.SecureRandom');
                SSLContext_init.implementation = function (keyManager, trustManager, secureRandom) {
                    SSLContext_init.call(this, keyManager, TrustManagers, secureRandom);
                };
            }
        } catch (e) { }

        // --- 3. OkHttp3 CertificatePinner Bypass ---
        try {
            var CertificatePinner = Java.use("okhttp3.CertificatePinner");
            CertificatePinner.check.overload('java.lang.String', 'java.util.List').implementation = function (hostname, certs) {
                return;
            };
        } catch (e) { }

        // --- 4. Android WebView (Chromium) SSL Bypass ---
        try {
            var X509Util = Java.use("org.chromium.net.X509Util");
            X509Util.verifyServerCertificates.overload('[[B', 'java.lang.String', 'java.lang.String').implementation = function (chain, authType, host) {
                return Java.use("java.util.Collections").emptyList();
            };
        } catch (e) { }

        try {
            var SslErrorHandler = Java.use("android.webkit.SslErrorHandler");
            SslErrorHandler.proceed.implementation = function () {
                this.proceed();
            };
            var WebViewClient = Java.use("android.webkit.WebViewClient");
            WebViewClient.onReceivedSslError.implementation = function (view, handler, error) {
                handler.proceed();
            };
        } catch (e) { }
        
        console.log("[+] All Network SSL Bypasses applied");
    });
}

function hook_java_cronet_only() {
    if (!Java.available) return;
    Java.perform(function() {
        try {
            var CertificatePinner = Java.use("okhttp3.CertificatePinner");
            CertificatePinner.check.overload('java.lang.String', 'java.util.List').implementation = function (hostname, certs) { return; };
        } catch (e) { }

        try {
            var X509Util = Java.use("org.chromium.net.X509Util");
            var emptyList = Java.use("java.util.Collections").emptyList();
            X509Util.verifyServerCertificates.overload('[[B', 'java.lang.String', 'java.lang.String').implementation = function (chain, authType, host) {
                return emptyList;
            };
        } catch (e) { }
        console.log("[+] Isolated Cronet/OkHttp Bypasses applied to fix Validity Too Long");
    });
}

// Ensure execution is slightly delayed until after _core_survival.js finishes MTE patching
// [CRASH FIX] ARMv9 BTI (Snapdragon) 하드웨어 보안 충돌로 인해 libssl.so 네이티브 훅 시
// ExoPlayer 프로세스가 동작 중 죽으므로(SIGBUS), 기본적으로 끕니다.
// setTimeout(hook_native_ssl, 50);

// [NORMAL MODE CRASH FIX] S22 (PAC/BTI) ExoPlayer Crash 방지
// Java 레이어의 네트워크를 무겁게 훅킹하면 오디오 엔진(ExoPlayer) 다운로드 스레드가 죽습니다!
// Java SSL 우회는 이미 적용된 LSPosed 모듈(TrustMeAlready 등)에 완전히 일임합니다.
// setTimeout(hook_java_all, 600);

// N-Log 및 Google Cronet 네트워크의 X509Util 한정으로 부분 훅 활성화! (ExoPlayer 영향 없음)
setTimeout(hook_java_cronet_only, 800);

import Foundation
import WebKit

/// The page side of the browser's password manager. It runs in MarkView's own content world, so
/// the page's scripts cannot call it or read what it holds. It reports two things: a submitted
/// login form (user name and password) and that a login form is on the page. Filling happens only
/// when the person asks, through `__mvFill`, which MarkView calls with the logins of this very site.
enum BrowserPasswordScript {
    static let handlerName = "markviewPasswords"

    static let source = #"""
    (function () {
      if (window.__mvPasswords) return;
      window.__mvPasswords = true;
      var post = function (body) { try { window.webkit.messageHandlers.markviewPasswords.postMessage(body); } catch (e) {} };

      function visible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        var rect = el.getBoundingClientRect();
        if (rect.width < 2 || rect.height < 2) return false;
        var style = getComputedStyle(el);
        return style.visibility !== 'hidden' && style.display !== 'none';
      }
      function passwordFields(root) {
        return Array.prototype.filter.call((root || document).querySelectorAll('input[type=password]'),
          function (el) { return visible(el) && !el.disabled; });
      }
      // The user name field is the nearest text-like input before the password field.
      function userField(password) {
        var scope = password.form || document;
        var candidates = Array.prototype.filter.call(scope.querySelectorAll('input'), function (el) {
          return /^(text|email|tel|)$/i.test(el.getAttribute('type') || '') && visible(el) && !el.disabled && !el.readOnly;
        });
        var found = null;
        candidates.forEach(function (el) {
          if (el.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING) found = el;
        });
        return found;
      }
      function setValue(el, value) {
        var setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(el, value);
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      }

      var lastReport = '';
      function report(password) {
        if (!password || !password.value) return;
        var user = userField(password);
        var body = { kind: 'submit', username: user ? user.value : '', password: password.value };
        var key = body.username + '\u0000' + body.password;
        if (key === lastReport) return;
        lastReport = key;
        setTimeout(function () { lastReport = ''; }, 3000);
        post(body);
      }
      document.addEventListener('submit', function (event) {
        var form = event.target;
        var password = form && form.querySelector ? form.querySelector('input[type=password]') : null;
        if (password) report(password);
      }, true);
      document.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' && event.target && event.target.type === 'password') report(event.target);
      }, true);
      document.addEventListener('click', function (event) {
        var button = event.target && event.target.closest ? event.target.closest('button, input[type=submit], [role=button]') : null;
        if (!button) return;
        var label = (button.innerText || button.value || button.getAttribute('aria-label') || '').toLowerCase();
        var submits = button.type === 'submit' || /log ?in|sign ?in|continue|next|submit|войти|вход/.test(label);
        if (!submits) return;
        var password = passwordFields(button.form || button.closest('form') || document)[0];
        if (password) report(password);
      }, true);

      var announced = false;
      function announce() {
        var has = passwordFields().length > 0;
        if (has !== announced) { announced = has; post({ kind: 'form', present: has }); }
      }
      announce();
      var timer = null;
      new MutationObserver(function () { clearTimeout(timer); timer = setTimeout(announce, 300); })
        .observe(document.documentElement, { childList: true, subtree: true });

      // Called by MarkView with the saved logins of this site, after the person chose to fill.
      window.__mvFill = function (logins, username) {
        var password = passwordFields()[0];
        if (!password || !logins || !logins.length) return false;
        var field = userField(password);
        var login = null;
        if (username) login = logins.filter(function (l) { return l.username === username; })[0];
        if (!login && field && field.value) login = logins.filter(function (l) { return l.username === field.value; })[0];
        login = login || logins[0];
        if (field) setValue(field, login.username);
        setValue(password, login.password);
        return true;
      };
    })();
    """#
}

/// Receives what the password script reports and hands it to the tab; it holds the tab weakly so
/// the web view's content controller does not keep the tab alive.
@MainActor
final class BrowserPasswordHandler: NSObject, WKScriptMessageHandler {
    weak var session: BrowserSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        let origin = message.frameInfo.securityOrigin
        guard PasswordRules.isEligible(scheme: origin.protocol, host: origin.host) else { return }
        let host = origin.host.lowercased().hasPrefix("www.") ? String(origin.host.lowercased().dropFirst(4)) : origin.host.lowercased()
        switch kind {
        case "submit":
            session?.loginSubmitted(host: host, username: body["username"] as? String ?? "", password: body["password"] as? String ?? "")
        case "form":
            session?.loginFormChanged(host: host, present: body["present"] as? Bool ?? false)
        default:
            break
        }
    }
}

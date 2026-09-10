using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using DataBase;
using Game.Code;

namespace Server.API
{
    /// <summary>
    /// Embedded Wonderland Online web portal.
    /// Provides account registration, authenticated web sessions and the Item Mall.
    /// </summary>
    public class RegistrationServer
    {
        private const string SessionCookieName = "wlo_portal_session";
        private static readonly TimeSpan SessionLifetime = TimeSpan.FromHours(12);
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

        private readonly ConcurrentDictionary<string, WebSession> _sessions =
            new ConcurrentDictionary<string, WebSession>(StringComparer.Ordinal);

        private HttpListener _listener;
        private Thread _listenerThread;
        private bool _isRunning;
        private readonly int _port;
        private readonly UserDataBase _userDb;

        private sealed class WebSession
        {
            public string Token;
            public uint UserId;
            public string Username;
            public DateTime ExpiresUtc;
        }

        public RegistrationServer(int port, UserDataBase userDb)
        {
            _port = port;
            _userDb = userDb;
        }

        public void Start()
        {
            if (_isRunning) return;

            _listener = new HttpListener();

            bool useExternalBinding = true;
            try
            {
                var testListener = new HttpListener();
                testListener.Prefixes.Add($"http://+:{_port}/");
                testListener.Start();
                testListener.Stop();
            }
            catch
            {
                useExternalBinding = false;
            }

            _listener.Prefixes.Add(useExternalBinding
                ? $"http://+:{_port}/"
                : $"http://localhost:{_port}/");

            try
            {
                _listener.Start();
                _isRunning = true;
                _listenerThread = new Thread(Listen)
                {
                    IsBackground = true,
                    Name = "WLO Web Portal"
                };
                _listenerThread.Start();

                DebugSystem.Write(useExternalBinding
                    ? $"[Portal] Started on http://*:{_port}/ (external access enabled)"
                    : $"[Portal] Started on http://localhost:{_port}/ (run as admin for external access)");
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[Portal] Failed to start: {ex.Message}");
            }
        }

        public void Stop()
        {
            _isRunning = false;
            try { _listener?.Stop(); } catch { }
            try { _listener?.Close(); } catch { }
            _sessions.Clear();
        }

        private void Listen()
        {
            while (_isRunning)
            {
                try
                {
                    var context = _listener.GetContext();
                    ThreadPool.QueueUserWorkItem(_ => HandleRequest(context));
                }
                catch (HttpListenerException)
                {
                    if (!_isRunning) break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
                catch (Exception ex)
                {
                    if (_isRunning)
                        DebugSystem.Write($"[Portal] Listener error: {ex.Message}");
                }
            }
        }

        private void HandleRequest(HttpListenerContext context)
        {
            var request = context.Request;
            var response = context.Response;
            response.Headers["X-Content-Type-Options"] = "nosniff";
            response.Headers["X-Frame-Options"] = "DENY";
            response.Headers["Referrer-Policy"] = "same-origin";
            response.Headers["Cache-Control"] = "no-store";

            try
            {
                string path = (request.Url?.AbsolutePath ?? "/").ToLowerInvariant();
                string body;

                if (request.HttpMethod == "OPTIONS")
                {
                    response.StatusCode = 204;
                    response.Close();
                    return;
                }

                if (path == "/api/login" && request.HttpMethod == "POST")
                {
                    RequirePortalRequest(request);
                    response.ContentType = "application/json; charset=utf-8";
                    body = HandleLogin(context);
                }
                else if (path == "/api/logout" && request.HttpMethod == "POST")
                {
                    RequirePortalRequest(request);
                    response.ContentType = "application/json; charset=utf-8";
                    body = HandleLogout(context);
                }
                else if (path == "/api/session")
                {
                    response.ContentType = "application/json; charset=utf-8";
                    body = HandleSessionInfo(request);
                }
                else if (path == "/api/buy" && request.HttpMethod == "POST")
                {
                    RequirePortalRequest(request);
                    response.ContentType = "application/json; charset=utf-8";
                    body = HandleApiBuy(context);
                }
                else if (path == "/api/catalog")
                {
                    response.ContentType = "application/json; charset=utf-8";
                    body = HandleApiCatalog();
                }
                else if (path == "/register" && request.HttpMethod == "POST")
                {
                    RequirePortalRequest(request);
                    response.ContentType = "application/json; charset=utf-8";
                    body = HandleRegister(context);
                }
                else
                {
                    response.ContentType = "text/html; charset=utf-8";
                    string view = "home";
                    if (path == "/shop" || path == "/itemmall" || path == "/mall") view = "shop";
                    else if (path == "/register" || path == "/register.html") view = "register";
                    else if (path == "/login" || path == "/signin") view = "login";
                    body = GetPortalPage(request, view);
                }

                WriteResponse(response, body);
            }
            catch (UnauthorizedAccessException ex)
            {
                response.StatusCode = 403;
                response.ContentType = "application/json; charset=utf-8";
                WriteResponse(response, ToJson(new { success = false, error = ex.Message }));
            }
            catch (Exception ex)
            {
                DebugSystem.Write($"[Portal] Request error: {ex.Message}\n{ex.StackTrace}");
                try
                {
                    response.StatusCode = 500;
                    response.ContentType = "application/json; charset=utf-8";
                    WriteResponse(response, ToJson(new { success = false, error = "Server error" }));
                }
                catch { }
            }
        }

        private static void RequirePortalRequest(HttpListenerRequest request)
        {
            // State-changing requests are only accepted from this portal's JavaScript.
            // Cross-origin forms cannot add this custom header without a CORS preflight,
            // and this server deliberately does not grant CORS access.
            if (!string.Equals(request.Headers["X-WLO-Portal"], "1", StringComparison.Ordinal))
                throw new UnauthorizedAccessException("Invalid portal request.");
        }

        private static void WriteResponse(HttpListenerResponse response, string text)
        {
            byte[] buffer = Encoding.UTF8.GetBytes(text ?? string.Empty);
            response.ContentEncoding = Encoding.UTF8;
            response.ContentLength64 = buffer.Length;
            response.OutputStream.Write(buffer, 0, buffer.Length);
            response.OutputStream.Close();
            response.Close();
        }

        private static string ToJson(object value)
        {
            return Json.Serialize(value);
        }

        private Dictionary<string, string> ReadForm(HttpListenerRequest request)
        {
            var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            using (var reader = new StreamReader(request.InputStream, request.ContentEncoding ?? Encoding.UTF8))
            {
                string body = reader.ReadToEnd();
                foreach (string pair in body.Split('&'))
                {
                    if (string.IsNullOrEmpty(pair)) continue;
                    string[] parts = pair.Split(new[] { '=' }, 2);
                    string key = Uri.UnescapeDataString((parts[0] ?? string.Empty).Replace('+', ' '));
                    string value = parts.Length > 1
                        ? Uri.UnescapeDataString((parts[1] ?? string.Empty).Replace('+', ' '))
                        : string.Empty;
                    values[key] = value;
                }
            }
            return values;
        }

        private string HandleLogin(HttpListenerContext context)
        {
            var form = ReadForm(context.Request);
            string username = GetFormValue(form, "username").Trim();
            string password = GetFormValue(form, "password");

            if (string.IsNullOrWhiteSpace(username) || string.IsNullOrEmpty(password))
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Enter your username and password." });
            }

            uint userId;
            string[] userData;
            if (!_userDb.GetUserData(username, password, out userId, out userData) || userId == 0)
            {
                context.Response.StatusCode = 401;
                return ToJson(new { success = false, error = "Incorrect username or password." });
            }

            WebSession session = CreateSession(userId, username);
            SetSessionCookie(context.Response, session.Token);
            DebugSystem.Write($"[Portal] Web login: {username} (UserID {userId})");

            return BuildSessionJson(session, true);
        }

        private string HandleLogout(HttpListenerContext context)
        {
            Cookie cookie = context.Request.Cookies[SessionCookieName];
            if (cookie != null && !string.IsNullOrEmpty(cookie.Value))
            {
                WebSession removed;
                _sessions.TryRemove(cookie.Value, out removed);
            }

            ExpireSessionCookie(context.Response);
            return ToJson(new { success = true });
        }

        private string HandleSessionInfo(HttpListenerRequest request)
        {
            WebSession session;
            if (!TryGetSession(request, out session))
                return ToJson(new { authenticated = false });

            return BuildSessionJson(session, false);
        }

        private string BuildSessionJson(WebSession session, bool successProperty)
        {
            var player = FindOnlinePlayer(session.UserId);
            int points = GetPoints(session.UserId, player);
            string characterName = player != null ? player.CharName : null;

            if (successProperty)
            {
                return ToJson(new
                {
                    success = true,
                    authenticated = true,
                    username = session.Username,
                    userId = session.UserId,
                    points,
                    online = player != null,
                    character = characterName
                });
            }

            return ToJson(new
            {
                authenticated = true,
                username = session.Username,
                userId = session.UserId,
                points,
                online = player != null,
                character = characterName
            });
        }

        private WebSession CreateSession(uint userId, string username)
        {
            CleanupExpiredSessions();

            byte[] tokenBytes = new byte[32];
            using (var rng = RandomNumberGenerator.Create())
                rng.GetBytes(tokenBytes);

            string token = Convert.ToBase64String(tokenBytes)
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');

            var session = new WebSession
            {
                Token = token,
                UserId = userId,
                Username = username,
                ExpiresUtc = DateTime.UtcNow.Add(SessionLifetime)
            };

            _sessions[token] = session;
            return session;
        }

        private bool TryGetSession(HttpListenerRequest request, out WebSession session)
        {
            session = null;
            Cookie cookie = request.Cookies[SessionCookieName];
            if (cookie == null || string.IsNullOrWhiteSpace(cookie.Value)) return false;

            if (!_sessions.TryGetValue(cookie.Value, out session)) return false;
            if (session.ExpiresUtc <= DateTime.UtcNow)
            {
                WebSession removed;
                _sessions.TryRemove(cookie.Value, out removed);
                session = null;
                return false;
            }

            session.ExpiresUtc = DateTime.UtcNow.Add(SessionLifetime);
            return true;
        }

        private void CleanupExpiredSessions()
        {
            DateTime now = DateTime.UtcNow;
            foreach (var kv in _sessions)
            {
                if (kv.Value == null || kv.Value.ExpiresUtc <= now)
                {
                    WebSession removed;
                    _sessions.TryRemove(kv.Key, out removed);
                }
            }
        }

        private static void SetSessionCookie(HttpListenerResponse response, string token)
        {
            var cookie = new Cookie(SessionCookieName, token, "/")
            {
                HttpOnly = true,
                Expires = DateTime.UtcNow.Add(SessionLifetime)
            };
            response.Cookies.Add(cookie);
        }

        private static void ExpireSessionCookie(HttpListenerResponse response)
        {
            var cookie = new Cookie(SessionCookieName, string.Empty, "/")
            {
                HttpOnly = true,
                Expires = DateTime.UtcNow.AddDays(-1)
            };
            response.Cookies.Add(cookie);
        }

        private string HandleApiCatalog()
        {
            var catalog = Game.PlayerRelated.ItemMallManager.GetCatalog();
            var items = catalog.Select(it => new
            {
                id = it.ItemID,
                name = it.ItemName,
                category = it.Category,
                cost = it.PointCost,
                count = it.Count
            }).ToArray();
            return ToJson(items);
        }

        private string HandleApiBuy(HttpListenerContext context)
        {
            WebSession session;
            if (!TryGetSession(context.Request, out session))
            {
                context.Response.StatusCode = 401;
                return ToJson(new { success = false, error = "Sign in to use the Item Mall." });
            }

            var form = ReadForm(context.Request);
            ushort itemId;
            if (!ushort.TryParse(GetFormValue(form, "item"), out itemId) || itemId == 0)
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Invalid Item Mall item." });
            }

            // Purchases are intentionally tied to the authenticated account. Never fall back
            // to another online player, even when only one player is connected.
            Game.Player target = FindOnlinePlayer(session.UserId);
            if (target == null)
            {
                context.Response.StatusCode = 409;
                return ToJson(new
                {
                    success = false,
                    error = "Your game account is not online. Log into Wonderland Online first, then purchase the item."
                });
            }

            bool ok = Game.PlayerRelated.ItemMallManager.PurchaseItem(target, itemId, 1);
            int points = Game.PlayerRelated.ItemMallManager.GetUserPoints(target);

            if (!ok)
            {
                context.Response.StatusCode = 400;
                return ToJson(new
                {
                    success = false,
                    points,
                    error = "Purchase failed. Check your IM Point balance and inventory space."
                });
            }

            target.SaveCharacterData();
            DebugSystem.Write($"[Portal] Item Mall purchase: Account={session.Username}, Character={target.CharName}, ItemID={itemId}, PointsLeft={points}");

            return ToJson(new
            {
                success = true,
                points,
                character = target.CharName,
                message = "Purchase complete. The item was delivered to your in-game inventory."
            });
        }

        private Game.Player FindOnlinePlayer(uint userId)
        {
            if (userId == 0) return null;
            try
            {
                var online = cGlobal.gCharacterDataBase?.GetOnlinePlayers();
                return online?.FirstOrDefault(p => p != null && p.UserID == userId);
            }
            catch
            {
                return null;
            }
        }

        private int GetPoints(uint userId, Game.Player onlinePlayer)
        {
            try
            {
                if (onlinePlayer != null)
                    return Game.PlayerRelated.ItemMallManager.GetUserPoints(onlinePlayer);
                return _userDb.GetIMPoints(userId);
            }
            catch
            {
                return 0;
            }
        }

        private string HandleRegister(HttpListenerContext context)
        {
            var form = ReadForm(context.Request);
            string username = GetFormValue(form, "username").Trim();
            string email = GetFormValue(form, "email").Trim();
            string password = GetFormValue(form, "password");
            string confirm = GetFormValue(form, "confirmPassword");

            if (username.Length < 3 || username.Length > 20)
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Username must be 3-20 characters." });
            }

            if (!username.All(ch => char.IsLetterOrDigit(ch) || ch == '_'))
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Username can only contain letters, numbers and underscores." });
            }

            if (string.IsNullOrWhiteSpace(email) || !email.Contains("@") || email.Length > 120)
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Enter a valid email address." });
            }

            if (string.IsNullOrEmpty(password) || password.Length < 4 || password.Length > 64)
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Password must be 4-64 characters." });
            }

            if (!string.Equals(password, confirm, StringComparison.Ordinal))
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Passwords do not match." });
            }

            string errorMessage;
            bool created = _userDb.RegisterUser(username, password, email, out errorMessage);
            if (!created)
            {
                context.Response.StatusCode = 409;
                return ToJson(new
                {
                    success = false,
                    error = string.IsNullOrWhiteSpace(errorMessage) ? "That username is already taken." : errorMessage
                });
            }

            // Sign the new account into the web portal immediately after successful creation.
            uint userId;
            string[] userData;
            if (_userDb.GetUserData(username, password, out userId, out userData) && userId > 0)
            {
                WebSession session = CreateSession(userId, username);
                SetSessionCookie(context.Response, session.Token);
            }

            DebugSystem.Write($"[Portal] Account created from web portal: {username}");
            return ToJson(new
            {
                success = true,
                message = "Account created successfully. You can now log into Wonderland Online."
            });
        }

        private static string GetFormValue(Dictionary<string, string> form, string key)
        {
            string value;
            return form != null && form.TryGetValue(key, out value) ? value ?? string.Empty : string.Empty;
        }

        private string GetPortalPage(HttpListenerRequest request, string view)
        {
            WebSession session;
            bool signedIn = TryGetSession(request, out session);
            Game.Player onlinePlayer = signedIn ? FindOnlinePlayer(session.UserId) : null;
            int points = signedIn ? GetPoints(session.UserId, onlinePlayer) : 0;
            int onlineCount = 0;
            try { onlineCount = cGlobal.gCharacterDataBase?.GetOnlinePlayers()?.Count ?? 0; } catch { }

            string username = signedIn ? WebUtility.HtmlEncode(session.Username) : string.Empty;
            string character = onlinePlayer != null ? WebUtility.HtmlEncode(onlinePlayer.CharName) : string.Empty;

            var catalog = Game.PlayerRelated.ItemMallManager.GetCatalog();
            var categories = catalog
                .Select(x => string.IsNullOrWhiteSpace(x.Category) ? "Other" : x.Category.Trim())
                .Distinct(StringComparer.OrdinalIgnoreCase)
                .OrderBy(x => x)
                .ToList();

            var itemCards = new StringBuilder();
            foreach (var item in catalog)
            {
                string itemName = WebUtility.HtmlEncode(item.ItemName ?? $"Item #{item.ItemID}");
                string categoryRaw = string.IsNullOrWhiteSpace(item.Category) ? "Other" : item.Category.Trim();
                string category = WebUtility.HtmlEncode(categoryRaw);
                string categoryKey = WebUtility.HtmlEncode(categoryRaw.ToLowerInvariant());

                itemCards.AppendLine($@"
                    <article class='shop-card' data-name='{itemName.ToLowerInvariant()}' data-category='{categoryKey}'>
                        <div class='item-art'><span>{GetCategoryIcon(categoryRaw)}</span><small>#{item.ItemID}</small></div>
                        <div class='item-copy'>
                            <div class='item-meta'><span>{category}</span><span>x{item.Count}</span></div>
                            <h3>{itemName}</h3>
                            <div class='item-bottom'>
                                <div class='price'><b>{item.PointCost}</b><span>IM</span></div>
                                <button class='buy-button' data-id='{item.ItemID}' data-name='{itemName}' data-cost='{item.PointCost}' onclick='buyItem(this)' {(signedIn ? string.Empty : "disabled")}>Buy now</button>
                            </div>
                        </div>
                    </article>");
            }

            var categoryButtons = new StringBuilder();
            categoryButtons.Append("<button class='filter active' data-filter='all' onclick='setFilter(this)'>All</button>");
            foreach (string cat in categories)
            {
                string encoded = WebUtility.HtmlEncode(cat);
                string key = WebUtility.HtmlEncode(cat.ToLowerInvariant());
                categoryButtons.Append($"<button class='filter' data-filter='{key}' onclick='setFilter(this)'>{encoded}</button>");
            }

            string accountArea = signedIn
                ? $@"<div class='account-chip'>
                        <div class='avatar'>{GetInitials(session.Username)}</div>
                        <div><small>Signed in</small><strong>{username}</strong></div>
                        <div class='mini-balance'><span>◆</span><b id='navPoints'>{points:N0}</b> IM</div>
                        <button class='ghost compact' onclick='logout()'>Sign out</button>
                    </div>"
                : "<a class='primary compact' href='/login'>Sign in</a>";

            string shopGate = signedIn
                ? $@"<div class='shop-account-banner'>
                        <div>
                            <span class='eyebrow'>ACCOUNT LINKED</span>
                            <h2>{username}</h2>
                            <p id='gameStatus'>{(onlinePlayer != null ? $"Online as {character} — purchases deliver instantly." : "Game offline — log into Wonderland Online before purchasing.")}</p>
                        </div>
                        <div class='balance-panel'><small>IM BALANCE</small><strong id='shopPoints'>{points:N0}</strong><span>points</span></div>
                    </div>"
                : @"<div class='shop-lock'>
                        <div class='lock-icon'>◆</div>
                        <div><span class='eyebrow'>MEMBERS ONLY</span><h2>Sign in to use the Item Mall</h2><p>Your web session is tied directly to your Wonderland account, so purchases can only go to your own character.</p></div>
                        <div class='lock-actions'><a class='primary' href='/login'>Sign in</a><a class='ghost' href='/register'>Create account</a></div>
                    </div>";

            string activeHome = view == "home" ? "active" : string.Empty;
            string activeShop = view == "shop" ? "active" : string.Empty;
            string activeRegister = view == "register" ? "active" : string.Empty;

            string homeDisplay = view == "home" ? "block" : "none";
            string shopDisplay = view == "shop" ? "block" : "none";
            string registerDisplay = view == "register" ? "block" : "none";
            string loginDisplay = view == "login" ? "block" : "none";

            return $@"<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Wonderland Online Portal</title>
<style>
:root {{ --bg:#050914; --panel:#0b1324; --panel2:#101b31; --line:rgba(255,255,255,.08); --text:#f6f8ff; --muted:#8f9bb3; --cyan:#43c6ff; --blue:#3a72ff; --violet:#8b5cf6; --gold:#ffcc66; --green:#51e29d; --red:#ff6b7a; }}
* {{ box-sizing:border-box; }}
html {{ scroll-behavior:smooth; }}
body {{ margin:0; min-height:100vh; font-family:'Segoe UI',Inter,Arial,sans-serif; color:var(--text); background:radial-gradient(circle at 12% 0%,rgba(58,114,255,.18),transparent 28%),radial-gradient(circle at 88% 10%,rgba(139,92,246,.14),transparent 32%),linear-gradient(180deg,#050914,#07101d 65%,#050914); }}
body:before {{ content:''; position:fixed; inset:0; pointer-events:none; opacity:.22; background-image:linear-gradient(rgba(255,255,255,.018) 1px,transparent 1px),linear-gradient(90deg,rgba(255,255,255,.018) 1px,transparent 1px); background-size:32px 32px; }}
a {{ color:inherit; text-decoration:none; }}
button,input {{ font:inherit; }}
.shell {{ width:min(1480px,calc(100% - 40px)); margin:0 auto; position:relative; z-index:1; }}
nav {{ height:82px; display:flex; align-items:center; justify-content:space-between; gap:24px; border-bottom:1px solid var(--line); }}
.brand {{ display:flex; align-items:center; gap:12px; font-weight:800; letter-spacing:.2px; }}
.brand-mark {{ width:42px; height:42px; display:grid; place-items:center; border-radius:13px; background:linear-gradient(135deg,var(--cyan),var(--violet)); box-shadow:0 10px 30px rgba(67,198,255,.2); color:#04101c; font-size:19px; }}
.brand span {{ display:block; font-size:10px; color:var(--cyan); letter-spacing:2.2px; font-weight:700; margin-top:2px; }}
.nav-links {{ display:flex; gap:6px; padding:5px; border:1px solid var(--line); background:rgba(8,15,28,.64); border-radius:14px; }}
.nav-links a {{ color:var(--muted); padding:9px 14px; border-radius:10px; font-size:14px; font-weight:650; }}
.nav-links a:hover,.nav-links a.active {{ color:white; background:rgba(255,255,255,.07); }}
.nav-right {{ display:flex; align-items:center; gap:10px; }}
.account-chip {{ display:flex; align-items:center; gap:10px; }}
.account-chip small,.account-chip strong {{ display:block; }}
.account-chip small {{ color:var(--muted); font-size:10px; text-transform:uppercase; letter-spacing:1px; }}
.avatar {{ width:35px; height:35px; display:grid; place-items:center; border-radius:11px; font-weight:800; background:linear-gradient(135deg,rgba(67,198,255,.22),rgba(139,92,246,.28)); border:1px solid rgba(67,198,255,.25); }}
.mini-balance {{ display:flex; align-items:center; gap:5px; color:var(--gold); padding:8px 10px; background:rgba(255,204,102,.07); border:1px solid rgba(255,204,102,.15); border-radius:10px; font-size:12px; }}
.primary,.ghost {{ border:0; cursor:pointer; border-radius:12px; padding:11px 17px; font-weight:750; display:inline-flex; align-items:center; justify-content:center; transition:.18s ease; }}
.primary {{ color:white; background:linear-gradient(135deg,var(--blue),var(--violet)); box-shadow:0 10px 25px rgba(58,114,255,.2); }}
.primary:hover {{ transform:translateY(-1px); box-shadow:0 14px 28px rgba(58,114,255,.28); }}
.ghost {{ color:#d7deed; background:rgba(255,255,255,.045); border:1px solid var(--line); }}
.ghost:hover {{ background:rgba(255,255,255,.08); }}
.compact {{ padding:8px 12px; border-radius:9px; font-size:12px; }}
main {{ padding:42px 0 70px; }}
.hero {{ min-height:590px; display:grid; grid-template-columns:1.05fr .95fr; gap:48px; align-items:center; }}
.eyebrow {{ color:var(--cyan); font-size:11px; letter-spacing:2.2px; font-weight:800; }}
.hero h1 {{ font-size:clamp(46px,6vw,82px); line-height:.98; margin:14px 0 20px; letter-spacing:-3px; max-width:850px; }}
.gradient-text {{ background:linear-gradient(90deg,var(--cyan),#7ea7ff 48%,#b88aff); -webkit-background-clip:text; color:transparent; }}
.hero p {{ max-width:700px; color:#aeb9ce; font-size:18px; line-height:1.7; }}
.hero-actions {{ display:flex; gap:12px; margin-top:28px; }}
.stats {{ display:flex; gap:28px; margin-top:38px; }}
.stat strong {{ font-size:21px; display:block; }} .stat span {{ color:var(--muted); font-size:12px; }}
.hero-card {{ position:relative; min-height:440px; border:1px solid var(--line); background:linear-gradient(160deg,rgba(16,27,49,.84),rgba(7,14,27,.68)); border-radius:28px; overflow:hidden; box-shadow:0 30px 80px rgba(0,0,0,.36); }}
.hero-card:before {{ content:''; position:absolute; width:330px; height:330px; border-radius:50%; right:-70px; top:-80px; background:radial-gradient(circle,rgba(67,198,255,.4),rgba(139,92,246,.12) 46%,transparent 70%); filter:blur(2px); }}
.portal-orb {{ width:220px; height:220px; border-radius:50%; position:absolute; right:80px; top:76px; border:1px solid rgba(111,210,255,.38); box-shadow:0 0 60px rgba(67,198,255,.16),inset 0 0 55px rgba(139,92,246,.14); background:radial-gradient(circle at 38% 34%,#9ce9ff 0 2%,#3478ff 11%,#6d48dc 32%,#0b1837 58%,#040814 72%); }}
.portal-orb:after {{ content:''; position:absolute; inset:-16px; border-radius:50%; border:1px dashed rgba(133,202,255,.3); animation:spin 18s linear infinite; }}
@keyframes spin {{ to {{ transform:rotate(360deg); }} }}
.hero-panel {{ position:absolute; left:28px; right:28px; bottom:28px; padding:20px; background:rgba(4,9,18,.72); border:1px solid var(--line); border-radius:18px; backdrop-filter:blur(16px); }}
.hero-panel strong {{ display:block; margin-bottom:6px; }} .hero-panel p {{ font-size:13px; margin:0; color:var(--muted); line-height:1.5; }}
.section-head {{ display:flex; justify-content:space-between; gap:20px; align-items:end; margin-bottom:24px; }}
.section-head h1 {{ font-size:42px; margin:6px 0 0; letter-spacing:-1.5px; }}
.section-head p {{ color:var(--muted); max-width:620px; margin:0; }}
.shop-account-banner,.shop-lock {{ display:flex; align-items:center; justify-content:space-between; gap:24px; padding:22px 24px; margin-bottom:22px; border:1px solid var(--line); border-radius:19px; background:linear-gradient(120deg,rgba(16,27,49,.84),rgba(10,17,31,.72)); }}
.shop-account-banner h2,.shop-lock h2 {{ margin:4px 0; }}
.shop-account-banner p,.shop-lock p {{ color:var(--muted); margin:0; }}
.balance-panel {{ min-width:170px; text-align:right; }} .balance-panel small,.balance-panel span {{ display:block; color:var(--muted); }} .balance-panel strong {{ font-size:32px; color:var(--gold); }}
.lock-icon {{ width:58px; height:58px; flex:0 0 58px; display:grid; place-items:center; border-radius:16px; color:var(--cyan); background:rgba(67,198,255,.08); border:1px solid rgba(67,198,255,.18); }}
.lock-actions {{ display:flex; gap:9px; }}
.shop-tools {{ display:flex; gap:12px; align-items:center; margin:22px 0; flex-wrap:wrap; }}
.search {{ flex:1; min-width:260px; position:relative; }}
.search input {{ width:100%; padding:13px 16px 13px 42px; color:white; background:rgba(9,17,31,.76); border:1px solid var(--line); border-radius:12px; outline:0; }}
.search input:focus {{ border-color:rgba(67,198,255,.45); box-shadow:0 0 0 3px rgba(67,198,255,.06); }}
.search span {{ position:absolute; left:15px; top:12px; color:var(--muted); }}
.filters {{ display:flex; gap:7px; flex-wrap:wrap; }}
.filter {{ border:1px solid var(--line); color:var(--muted); background:rgba(255,255,255,.035); padding:9px 12px; border-radius:10px; cursor:pointer; }}
.filter:hover,.filter.active {{ color:white; border-color:rgba(67,198,255,.25); background:rgba(67,198,255,.09); }}
.shop-grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(245px,1fr)); gap:14px; }}
.shop-card {{ min-height:230px; display:flex; flex-direction:column; overflow:hidden; border:1px solid var(--line); border-radius:17px; background:linear-gradient(155deg,rgba(16,27,49,.82),rgba(8,15,28,.84)); transition:.18s ease; }}
.shop-card:hover {{ transform:translateY(-3px); border-color:rgba(67,198,255,.24); box-shadow:0 18px 36px rgba(0,0,0,.2); }}
.item-art {{ height:92px; padding:16px; display:flex; align-items:start; justify-content:space-between; background:radial-gradient(circle at 20% 10%,rgba(67,198,255,.13),transparent 45%),linear-gradient(135deg,rgba(58,114,255,.07),rgba(139,92,246,.08)); border-bottom:1px solid var(--line); }}
.item-art span {{ font-size:29px; }} .item-art small {{ color:#6e7d98; font-family:Consolas,monospace; }}
.item-copy {{ padding:15px; flex:1; display:flex; flex-direction:column; }}
.item-meta {{ display:flex; justify-content:space-between; color:var(--cyan); font-size:10px; letter-spacing:1px; text-transform:uppercase; font-weight:800; }}
.item-copy h3 {{ font-size:15px; line-height:1.35; margin:9px 0 18px; }}
.item-bottom {{ margin-top:auto; display:flex; align-items:center; justify-content:space-between; gap:10px; }}
.price b {{ font-size:21px; color:var(--gold); }} .price span {{ font-size:10px; color:var(--muted); margin-left:4px; }}
.buy-button {{ border:0; padding:9px 13px; border-radius:9px; background:linear-gradient(135deg,#3478ff,#7655e9); color:white; font-weight:750; cursor:pointer; }}
.buy-button:hover:not(:disabled) {{ filter:brightness(1.1); }} .buy-button:disabled {{ opacity:.35; cursor:not-allowed; }}
.auth-wrap {{ width:min(1080px,100%); margin:30px auto 0; display:grid; grid-template-columns:.92fr 1.08fr; border:1px solid var(--line); border-radius:26px; overflow:hidden; background:rgba(10,18,33,.72); box-shadow:0 30px 80px rgba(0,0,0,.28); }}
.auth-side {{ padding:48px; background:radial-gradient(circle at 20% 10%,rgba(67,198,255,.16),transparent 42%),linear-gradient(145deg,rgba(58,114,255,.12),rgba(139,92,246,.11)); }}
.auth-side h2 {{ font-size:36px; margin:12px 0; letter-spacing:-1px; }} .auth-side p {{ color:#aab6cb; line-height:1.65; }}
.auth-list {{ margin-top:28px; display:grid; gap:12px; color:#cbd5e5; font-size:13px; }} .auth-list div {{ display:flex; gap:10px; }} .auth-list b {{ color:var(--green); }}
.auth-form {{ padding:48px; }} .auth-form h1 {{ margin:0 0 6px; }} .auth-form>p {{ color:var(--muted); margin:0 0 26px; }}
.field {{ margin-bottom:14px; }} .field label {{ display:block; font-size:11px; color:#a8b3c8; font-weight:750; margin-bottom:7px; text-transform:uppercase; letter-spacing:.9px; }}
.field input {{ width:100%; padding:13px 14px; color:white; background:#080f1d; border:1px solid var(--line); border-radius:11px; outline:0; }}
.field input:focus {{ border-color:rgba(67,198,255,.5); box-shadow:0 0 0 3px rgba(67,198,255,.06); }}
.form-row {{ display:grid; grid-template-columns:1fr 1fr; gap:12px; }}
.form-submit {{ width:100%; margin-top:8px; padding:13px 16px; }}
.form-note {{ font-size:12px; color:var(--muted); margin-top:16px; text-align:center; }}
.alert {{ display:none; margin-bottom:16px; padding:11px 13px; border-radius:10px; font-size:13px; }} .alert.show {{ display:block; }} .alert.error {{ color:#ffd6dc; background:rgba(255,107,122,.1); border:1px solid rgba(255,107,122,.2); }} .alert.success {{ color:#c9ffe2; background:rgba(81,226,157,.1); border:1px solid rgba(81,226,157,.2); }}
.toast {{ position:fixed; right:24px; bottom:24px; z-index:50; width:min(390px,calc(100% - 48px)); transform:translateY(20px); opacity:0; pointer-events:none; padding:15px 17px; border-radius:13px; background:#0c1728; border:1px solid var(--line); box-shadow:0 18px 50px rgba(0,0,0,.4); transition:.2s ease; }} .toast.show {{ opacity:1; transform:translateY(0); }} .toast.good {{ border-color:rgba(81,226,157,.3); }} .toast.bad {{ border-color:rgba(255,107,122,.3); }}
footer {{ padding:28px 0 42px; border-top:1px solid var(--line); color:#74829b; font-size:12px; display:flex; justify-content:space-between; gap:20px; }}
@media(max-width:900px) {{ .nav-links {{ display:none; }} .account-chip>div:nth-child(2),.mini-balance {{ display:none; }} .hero {{ grid-template-columns:1fr; }} .hero-card {{ min-height:360px; }} .auth-wrap {{ grid-template-columns:1fr; }} .auth-side {{ display:none; }} .shop-account-banner,.shop-lock {{ align-items:flex-start; flex-direction:column; }} .balance-panel {{ text-align:left; }} }}
@media(max-width:560px) {{ .shell {{ width:min(100% - 24px,1480px); }} nav {{ height:70px; }} .brand>div:last-child {{ display:none; }} main {{ padding-top:26px; }} .hero {{ min-height:auto; }} .hero h1 {{ font-size:48px; }} .hero-card {{ min-height:320px; }} .portal-orb {{ width:170px; height:170px; right:50%; transform:translateX(50%); }} .auth-form {{ padding:28px 20px; }} .form-row {{ grid-template-columns:1fr; }} .shop-grid {{ grid-template-columns:1fr; }} }}
</style>
</head>
<body>
<div class='shell'>
<nav>
    <a class='brand' href='/'><div class='brand-mark'>W</div><div>Wonderland Online<span>PRIVATE SERVER</span></div></a>
    <div class='nav-links'>
        <a class='{activeHome}' href='/'>Home</a>
        <a class='{activeShop}' href='/shop'>Item Mall</a>
        <a class='{activeRegister}' href='/register'>Create account</a>
    </div>
    <div class='nav-right'>{accountArea}</div>
</nav>
<main>
<section id='homeView' style='display:{homeDisplay}'>
    <div class='hero'>
        <div>
            <span class='eyebrow'>A CLASSIC WORLD, REBORN</span>
            <h1>Return to <span class='gradient-text'>Wonderland.</span></h1>
            <p>Create your server account, enter the world and manage your Item Mall purchases from one modern portal. Your portal login is the same account you use in the game.</p>
            <div class='hero-actions'>
                {(signedIn ? "<a class='primary' href='/shop'>Open Item Mall</a>" : "<a class='primary' href='/register'>Create account</a><a class='ghost' href='/login'>Sign in</a>")}
            </div>
            <div class='stats'><div class='stat'><strong>{onlineCount}</strong><span>Players online</span></div><div class='stat'><strong>{catalog.Count}</strong><span>Mall items</span></div><div class='stat'><strong>6414</strong><span>Game port</span></div></div>
        </div>
        <div class='hero-card'>
            <div class='portal-orb'></div>
            <div class='hero-panel'><span class='eyebrow'>SERVER PORTAL</span><strong>One account. One character network.</strong><p>Account creation writes directly to the Wonderland users database. Item Mall purchases are locked to the signed-in account.</p></div>
        </div>
    </div>
</section>
<section id='shopView' style='display:{shopDisplay}'>
    <div class='section-head'><div><span class='eyebrow'>ITEM MALL</span><h1>Premium shop</h1></div><p>Browse the live server catalog. You must be signed into the portal, and your game account must be online, before an item can be delivered.</p></div>
    {shopGate}
    <div class='shop-tools'><div class='search'><span>⌕</span><input id='shopSearch' type='search' placeholder='Search items...' oninput='filterItems()'></div><div class='filters'>{categoryButtons}</div></div>
    <div id='shopGrid' class='shop-grid'>{itemCards}</div>
</section>
<section id='registerView' style='display:{registerDisplay}'>
    <div class='auth-wrap'>
        <div class='auth-side'><span class='eyebrow'>NEW ADVENTURER</span><h2>Create your Wonderland account.</h2><p>Your account is created directly in the server database and can be used immediately in the Rhode Island client.</p><div class='auth-list'><div><b>✓</b><span>Username availability is checked before creation.</span></div><div><b>✓</b><span>The same credentials work in the game and this portal.</span></div><div><b>✓</b><span>Portal sessions keep Item Mall purchases tied to your account.</span></div></div></div>
        <form class='auth-form' id='registerForm' onsubmit='registerAccount(event)'><span class='eyebrow'>CREATE ACCOUNT</span><h1>Join the server</h1><p>Choose credentials for your Wonderland account.</p><div id='registerAlert' class='alert'></div><div class='field'><label>Username</label><input name='username' minlength='3' maxlength='20' pattern='[A-Za-z0-9_]+' autocomplete='username' required placeholder='Choose a username'></div><div class='field'><label>Email</label><input name='email' type='email' maxlength='120' autocomplete='email' required placeholder='you@example.com'></div><div class='form-row'><div class='field'><label>Password</label><input name='password' type='password' minlength='4' maxlength='64' autocomplete='new-password' required placeholder='Password'></div><div class='field'><label>Confirm password</label><input name='confirmPassword' type='password' minlength='4' maxlength='64' autocomplete='new-password' required placeholder='Repeat password'></div></div><button class='primary form-submit' type='submit'>Create account</button><div class='form-note'>Already registered? <a href='/login' style='color:var(--cyan)'>Sign in here</a></div></form>
    </div>
</section>
<section id='loginView' style='display:{loginDisplay}'>
    <div class='auth-wrap'>
        <div class='auth-side'><span class='eyebrow'>WELCOME BACK</span><h2>Sign in before you shop.</h2><p>The Item Mall no longer guesses which online player is buying. Your web session is linked to your exact Wonderland User ID.</p><div class='auth-list'><div><b>✓</b><span>Purchases cannot be sent to another player's character.</span></div><div><b>✓</b><span>See your current IM Point balance.</span></div><div><b>✓</b><span>Items deliver directly while your character is online.</span></div></div></div>
        <form class='auth-form' id='loginForm' onsubmit='loginAccount(event)'><span class='eyebrow'>ACCOUNT LOGIN</span><h1>Sign in</h1><p>Use the same username and password you use in game.</p><div id='loginAlert' class='alert'></div><div class='field'><label>Username</label><input name='username' autocomplete='username' required placeholder='Username'></div><div class='field'><label>Password</label><input name='password' type='password' autocomplete='current-password' required placeholder='Password'></div><button class='primary form-submit' type='submit'>Sign in to portal</button><div class='form-note'>Need an account? <a href='/register' style='color:var(--cyan)'>Create one</a></div></form>
    </div>
</section>
</main>
<footer><span>Wonderland Online Private Server Portal</span><span>Game server: 127.0.0.1:6414 · Portal: :{_port}</span></footer>
</div>
<div id='toast' class='toast'></div>
<script>
let activeFilter='all';
function formBody(form){{ return new URLSearchParams(new FormData(form)); }}
async function portalPost(url,body){{
    const response=await fetch(url,{{method:'POST',headers:{{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8','X-WLO-Portal':'1'}},body:body}});
    let data; try{{ data=await response.json(); }}catch{{ data={{success:false,error:'Invalid server response'}}; }}
    if(!response.ok && !data.error) data.error='Request failed';
    return data;
}}
function setAlert(id,text,good){{ const el=document.getElementById(id); if(!el)return; el.className='alert show '+(good?'success':'error'); el.textContent=text; }}
function toast(text,good){{ const el=document.getElementById('toast'); el.textContent=text; el.className='toast show '+(good?'good':'bad'); clearTimeout(window.__toastTimer); window.__toastTimer=setTimeout(()=>el.className='toast',3600); }}
async function registerAccount(e){{
    e.preventDefault(); const form=e.target; const p=form.password.value,c=form.confirmPassword.value;
    if(p!==c){{setAlert('registerAlert','Passwords do not match.',false);return;}}
    const btn=form.querySelector('button[type=submit]'); btn.disabled=true; btn.textContent='Creating account...';
    try{{ const d=await portalPost('/register',formBody(form)); if(d.success){{setAlert('registerAlert',d.message||'Account created.',true);setTimeout(()=>location.href='/shop',700);}}else setAlert('registerAlert',d.error||d.message||'Registration failed.',false); }}catch{{setAlert('registerAlert','Could not reach the portal server.',false);}}
    finally{{btn.disabled=false;btn.textContent='Create account';}}
}}
async function loginAccount(e){{
    e.preventDefault(); const form=e.target; const btn=form.querySelector('button[type=submit]'); btn.disabled=true; btn.textContent='Signing in...';
    try{{ const d=await portalPost('/api/login',formBody(form)); if(d.success){{setAlert('loginAlert','Signed in. Opening Item Mall...',true);setTimeout(()=>location.href='/shop',450);}}else setAlert('loginAlert',d.error||'Sign in failed.',false); }}catch{{setAlert('loginAlert','Could not reach the portal server.',false);}}
    finally{{btn.disabled=false;btn.textContent='Sign in to portal';}}
}}
async function logout(){{ try{{await portalPost('/api/logout','');}}finally{{location.href='/';}} }}
async function buyItem(btn){{
    if(btn.disabled)return; const id=btn.dataset.id,name=btn.dataset.name,cost=btn.dataset.cost;
    if(!confirm('Purchase '+name+' for '+cost+' IM Points?'))return;
    const original=btn.textContent; btn.disabled=true; btn.textContent='Purchasing...';
    try{{ const d=await portalPost('/api/buy',new URLSearchParams({{item:id}})); if(d.success){{toast(d.message||'Purchase complete.',true); if(document.getElementById('navPoints'))document.getElementById('navPoints').textContent=Number(d.points||0).toLocaleString(); if(document.getElementById('shopPoints'))document.getElementById('shopPoints').textContent=Number(d.points||0).toLocaleString();}}else toast(d.error||'Purchase failed.',false); }}catch{{toast('Could not reach the Item Mall service.',false);}}
    finally{{btn.disabled=false;btn.textContent=original;}}
}}
function setFilter(btn){{ document.querySelectorAll('.filter').forEach(x=>x.classList.remove('active'));btn.classList.add('active');activeFilter=btn.dataset.filter||'all';filterItems(); }}
function filterItems(){{ const q=(document.getElementById('shopSearch')?.value||'').toLowerCase().trim();document.querySelectorAll('.shop-card').forEach(card=>{{const cat=card.dataset.category||'',name=card.dataset.name||'';card.style.display=((activeFilter==='all'||cat===activeFilter)&&(!q||name.includes(q)))?'flex':'none';}}); }}
async function refreshSession(){{
    try{{ const r=await fetch('/api/session',{{cache:'no-store'}}); const d=await r.json(); if(!d.authenticated)return; if(document.getElementById('navPoints'))document.getElementById('navPoints').textContent=Number(d.points||0).toLocaleString(); if(document.getElementById('shopPoints'))document.getElementById('shopPoints').textContent=Number(d.points||0).toLocaleString(); const status=document.getElementById('gameStatus'); if(status)status.textContent=d.online?('Online as '+d.character+' — purchases deliver instantly.'):'Game offline — log into Wonderland Online before purchasing.'; }}catch{{}}
}}
setInterval(refreshSession,15000);
</script>
</body>
</html>";
        }

        private static string GetInitials(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return "W";
            string trimmed = value.Trim();
            if (trimmed.Length == 1) return WebUtility.HtmlEncode(trimmed.ToUpperInvariant());
            return WebUtility.HtmlEncode(trimmed.Substring(0, 2).ToUpperInvariant());
        }

        private static string GetCategoryIcon(string category)
        {
            string c = (category ?? string.Empty).ToLowerInvariant();
            if (c.Contains("weapon")) return "⚔";
            if (c.Contains("armor") || c.Contains("armour")) return "◈";
            if (c.Contains("grocery") || c.Contains("food")) return "✦";
            if (c.Contains("vehicle")) return "◇";
            if (c.Contains("pet")) return "◆";
            return "✧";
        }
    }
}

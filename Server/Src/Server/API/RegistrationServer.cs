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
                DebugSystem.Write($"[Portal] Item images: {GetItemImageDirectory()}");
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

                if (path.StartsWith("/images/items/"))
                {
                    ServeItemImage(response, path);
                    return;
                }

                if (request.HttpMethod == "OPTIONS")
                {
                    response.StatusCode = 204;
                    response.Close();
                    return;
                }

                string body;
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

        private static void WriteBytes(HttpListenerResponse response, byte[] bytes, string contentType)
        {
            byte[] buffer = bytes ?? new byte[0];
            response.ContentType = contentType;
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

        private string BuildSessionJson(WebSession session, bool includeSuccess)
        {
            var player = FindOnlinePlayer(session.UserId);
            int points = GetPoints(session.UserId, player);
            string characterName = player != null ? player.CharName : null;

            if (includeSuccess)
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
            response.Cookies.Add(new Cookie(SessionCookieName, token, "/")
            {
                HttpOnly = true,
                Expires = DateTime.UtcNow.Add(SessionLifetime)
            });
        }

        private static void ExpireSessionCookie(HttpListenerResponse response)
        {
            response.Cookies.Add(new Cookie(SessionCookieName, string.Empty, "/")
            {
                HttpOnly = true,
                Expires = DateTime.UtcNow.AddDays(-1)
            });
        }

        private string HandleApiCatalog()
        {
            var items = Game.PlayerRelated.ItemMallManager.GetCatalog().Select(it => new
            {
                id = it.ItemID,
                name = it.ItemName,
                category = it.Category,
                cost = it.PointCost,
                count = it.Count,
                image = "/images/items/" + it.ItemID
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
            byte advertisedCount;
            if (!ushort.TryParse(GetFormValue(form, "item"), out itemId) || itemId == 0)
            {
                context.Response.StatusCode = 400;
                return ToJson(new { success = false, error = "Invalid Item Mall item." });
            }
            if (!byte.TryParse(GetFormValue(form, "count"), out advertisedCount) || advertisedCount == 0)
                advertisedCount = 1;

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

            // Synchronize the online account with the authoritative users.IM balance before purchase.
            if (target.UserAccount != null)
            {
                int dbPoints = _userDb.GetIMPoints(session.UserId);
                target.UserAccount.IM = Math.Max(0, dbPoints);
            }

            bool ok = Game.PlayerRelated.ItemMallManager.PurchaseAdvertisedItem(target, itemId, advertisedCount, false);
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
            DebugSystem.Write($"[Portal] Item Mall purchase: Account={session.Username}, Character={target.CharName}, ItemID={itemId}, Count={advertisedCount}, PointsLeft={points}");
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
                return ToJson(new { success = false, error = string.IsNullOrWhiteSpace(errorMessage) ? "That username is already taken." : errorMessage });
            }

            uint userId;
            string[] userData;
            if (_userDb.GetUserData(username, password, out userId, out userData) && userId > 0)
            {
                WebSession session = CreateSession(userId, username);
                SetSessionCookie(context.Response, session.Token);
            }

            DebugSystem.Write($"[Portal] Account created from web portal: {username}");
            return ToJson(new { success = true, message = "Account created successfully. You can now log into Wonderland Online." });
        }

        private static string GetFormValue(Dictionary<string, string> form, string key)
        {
            string value;
            return form != null && form.TryGetValue(key, out value) ? value ?? string.Empty : string.Empty;
        }

        private static string GetItemImageDirectory()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            string[] candidates =
            {
                Path.Combine(baseDir, "Web", "images", "items"),
                Path.GetFullPath(Path.Combine(baseDir, "..", "..", "Web", "images", "items")),
                Path.Combine(Directory.GetCurrentDirectory(), "Web", "images", "items")
            };

            foreach (string candidate in candidates)
            {
                try
                {
                    if (Directory.Exists(candidate)) return candidate;
                }
                catch { }
            }

            string preferred = candidates[1];
            try { Directory.CreateDirectory(preferred); } catch { }
            return preferred;
        }

        private static void ServeItemImage(HttpListenerResponse response, string path)
        {
            string token = path.Substring("/images/items/".Length).Trim('/');
            ushort itemId;
            if (!ushort.TryParse(token, out itemId) || itemId == 0)
            {
                response.StatusCode = 404;
                WritePlaceholderImage(response, 0);
                return;
            }

            string file = Path.Combine(GetItemImageDirectory(), itemId + ".png");
            if (File.Exists(file))
            {
                response.Headers["Cache-Control"] = "public, max-age=3600";
                WriteBytes(response, File.ReadAllBytes(file), "image/png");
                return;
            }

            response.Headers["Cache-Control"] = "public, max-age=120";
            WritePlaceholderImage(response, itemId);
        }

        private static void WritePlaceholderImage(HttpListenerResponse response, ushort itemId)
        {
            string svg = "<svg xmlns='http://www.w3.org/2000/svg' width='256' height='256' viewBox='0 0 256 256'>" +
                         "<defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop stop-color='#dff7ff'/><stop offset='1' stop-color='#bce7f7'/></linearGradient></defs>" +
                         "<rect width='256' height='256' rx='28' fill='url(#g)'/><circle cx='128' cy='106' r='48' fill='#fff' fill-opacity='.72' stroke='#4f9cbc' stroke-width='5'/>" +
                         "<path d='M104 112l19 19 34-42' fill='none' stroke='#e6a72c' stroke-width='10' stroke-linecap='round' stroke-linejoin='round'/>" +
                         "<text x='128' y='190' text-anchor='middle' font-family='Arial' font-size='18' font-weight='700' fill='#31627b'>Item #" + itemId + "</text></svg>";
            WriteBytes(response, Encoding.UTF8.GetBytes(svg), "image/svg+xml; charset=utf-8");
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
                string rawName = item.ItemName ?? $"Item #{item.ItemID}";
                string itemName = WebUtility.HtmlEncode(rawName);
                string searchName = WebUtility.HtmlEncode(rawName.ToLowerInvariant());
                string categoryRaw = string.IsNullOrWhiteSpace(item.Category) ? "Other" : item.Category.Trim();
                string category = WebUtility.HtmlEncode(categoryRaw);
                string categoryKey = WebUtility.HtmlEncode(categoryRaw.ToLowerInvariant());

                itemCards.AppendLine($@"
<article class='shop-card' data-name='{searchName}' data-category='{categoryKey}'>
    <div class='item-art'>
        <div class='item-picture'><img src='/images/items/{item.ItemID}' alt='{itemName}' loading='lazy'></div>
        <span class='item-id'>#{item.ItemID}</span>
        {(item.IsHot > 0 ? "<span class='ribbon hot'>HOT</span>" : item.IsNew > 0 ? "<span class='ribbon new'>NEW</span>" : string.Empty)}
    </div>
    <div class='item-copy'>
        <div class='item-meta'><span>{category}</span><span>x{Math.Max((byte)1, item.Count)}</span></div>
        <h3>{itemName}</h3>
        <div class='item-bottom'>
            <div class='price'><b>{item.PointCost:N0}</b><span>IM</span></div>
            <button class='buy-button' data-id='{item.ItemID}' data-count='{Math.Max((byte)1, item.Count)}' data-name='{itemName}' data-cost='{item.PointCost}' onclick='buyItem(this)' {(signedIn ? string.Empty : "disabled")}>Buy</button>
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
                ? $@"<div class='account-chip'><div class='avatar'>{GetInitials(session.Username)}</div><div><small>Adventurer</small><strong>{username}</strong></div><div class='mini-balance'><span>◆</span><b id='navPoints'>{points:N0}</b> IM</div><button class='ghost compact' onclick='logout()'>Sign out</button></div>"
                : "<a class='primary compact' href='/login'>Sign in</a>";

            string shopGate = signedIn
                ? $@"<div class='shop-account-banner'><div><span class='eyebrow'>ADVENTURER ACCOUNT</span><h2>{username}</h2><p id='gameStatus'>{(onlinePlayer != null ? $"Online as {character} — purchases deliver instantly." : "Game offline — log into Wonderland Online before purchasing.")}</p></div><div class='balance-panel'><small>IM POINTS</small><strong id='shopPoints'>{points:N0}</strong><span>available</span></div></div>"
                : @"<div class='shop-lock'><div class='lock-icon'>◆</div><div><span class='eyebrow'>ITEM MALL</span><h2>Sign in before shopping</h2><p>Your portal account is linked to your game User ID, so purchases can only be delivered to your own character.</p></div><div class='lock-actions'><a class='primary' href='/login'>Sign in</a><a class='ghost' href='/register'>Create account</a></div></div>";

            string html = GetTemplate();
            html = html.Replace("@@ACTIVE_HOME@@", view == "home" ? "active" : string.Empty)
                       .Replace("@@ACTIVE_SHOP@@", view == "shop" ? "active" : string.Empty)
                       .Replace("@@ACTIVE_REGISTER@@", view == "register" ? "active" : string.Empty)
                       .Replace("@@HOME_DISPLAY@@", view == "home" ? "block" : "none")
                       .Replace("@@SHOP_DISPLAY@@", view == "shop" ? "block" : "none")
                       .Replace("@@REGISTER_DISPLAY@@", view == "register" ? "block" : "none")
                       .Replace("@@LOGIN_DISPLAY@@", view == "login" ? "block" : "none")
                       .Replace("@@ACCOUNT_AREA@@", accountArea)
                       .Replace("@@SHOP_GATE@@", shopGate)
                       .Replace("@@CATEGORY_BUTTONS@@", categoryButtons.ToString())
                       .Replace("@@ITEM_CARDS@@", itemCards.ToString())
                       .Replace("@@ONLINE_COUNT@@", onlineCount.ToString())
                       .Replace("@@CATALOG_COUNT@@", catalog.Count.ToString())
                       .Replace("@@PORT@@", _port.ToString())
                       .Replace("@@HOME_ACTIONS@@", signedIn ? "<a class='primary' href='/shop'>Visit Item Mall</a>" : "<a class='primary' href='/register'>Create account</a><a class='ghost' href='/login'>Sign in</a>");
            return html;
        }

        private static string GetInitials(string value)
        {
            if (string.IsNullOrWhiteSpace(value)) return "W";
            string trimmed = value.Trim();
            return WebUtility.HtmlEncode((trimmed.Length == 1 ? trimmed : trimmed.Substring(0, 2)).ToUpperInvariant());
        }

        private static string GetTemplate()
        {
            return @"<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>Wonderland Online Private Server</title>
<style>
:root{--sky:#8fd9f6;--sky2:#dff8ff;--sea:#37a9d0;--deep:#116a99;--navy:#174d6d;--gold:#f2b33e;--gold2:#ffd978;--cream:#fff9e9;--paper:#fffdf6;--ink:#28495b;--muted:#668699;--green:#44a76c;--red:#d85858;--line:rgba(28,94,125,.18)}
*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;min-height:100vh;font-family:'Trebuchet MS','Segoe UI',Arial,sans-serif;color:var(--ink);background:linear-gradient(180deg,var(--sky2) 0,#bcecff 34%,#78cce9 55%,#35a6cf 55.2%,#167da9 100%);background-attachment:fixed}body:before{content:'';position:fixed;left:0;right:0;bottom:0;height:34vh;pointer-events:none;opacity:.32;background:repeating-radial-gradient(ellipse at 50% 110%,transparent 0 32px,rgba(255,255,255,.28) 33px 35px,transparent 36px 68px)}body:after{content:'';position:fixed;left:-5%;right:-5%;top:106px;height:120px;pointer-events:none;opacity:.7;background:radial-gradient(ellipse at 12% 50%,white 0 18%,transparent 19%),radial-gradient(ellipse at 22% 55%,white 0 12%,transparent 13%),radial-gradient(ellipse at 78% 35%,white 0 14%,transparent 15%),radial-gradient(ellipse at 88% 42%,white 0 18%,transparent 19%);filter:blur(1px)}a{color:inherit;text-decoration:none}button,input{font:inherit}.shell{width:min(1460px,calc(100% - 34px));margin:0 auto;position:relative;z-index:1}nav{height:88px;margin-top:14px;padding:0 18px;display:flex;align-items:center;justify-content:space-between;gap:20px;border:2px solid rgba(255,255,255,.74);border-bottom-color:rgba(25,93,126,.26);border-radius:24px;background:linear-gradient(180deg,rgba(255,255,255,.92),rgba(238,251,255,.84));box-shadow:0 13px 35px rgba(18,83,114,.18),inset 0 0 0 3px rgba(111,203,236,.12);backdrop-filter:blur(14px)}.brand{display:flex;align-items:center;gap:12px;font-weight:900;color:var(--deep);text-shadow:0 1px white}.brand-mark{width:48px;height:48px;display:grid;place-items:center;border-radius:50%;background:radial-gradient(circle at 35% 25%,#fff6b0,#ffd45e 35%,#e9a52e 68%,#b86c1e);border:3px solid white;box-shadow:0 3px 0 #bd7c28,0 7px 16px rgba(38,111,142,.18);color:#fff;font-size:24px}.brand span{display:block;font-size:10px;color:#4f9dbb;letter-spacing:2px;margin-top:1px}.nav-links{display:flex;gap:6px;padding:5px;background:rgba(118,203,235,.14);border:1px solid rgba(45,130,166,.15);border-radius:15px}.nav-links a{padding:9px 15px;border-radius:11px;color:#47768c;font-size:14px;font-weight:800}.nav-links a:hover,.nav-links a.active{color:#fff;background:linear-gradient(180deg,#62c5e6,#2998c0);box-shadow:inset 0 1px rgba(255,255,255,.65),0 3px 7px rgba(26,115,151,.18)}.nav-right,.account-chip{display:flex;align-items:center;gap:9px}.account-chip small,.account-chip strong{display:block}.account-chip small{font-size:9px;color:#7194a4;text-transform:uppercase;letter-spacing:1px}.avatar{width:37px;height:37px;display:grid;place-items:center;border-radius:50%;font-weight:900;color:white;background:linear-gradient(145deg,#72d5ee,#2e9fc8);border:2px solid white;box-shadow:0 3px 8px rgba(25,103,137,.22)}.mini-balance{display:flex;align-items:center;gap:5px;color:#9b6813;padding:8px 10px;background:#fff5ce;border:1px solid #efcf74;border-radius:10px;font-size:12px}.primary,.ghost{border:0;cursor:pointer;border-radius:13px;padding:11px 18px;font-weight:900;display:inline-flex;align-items:center;justify-content:center;transition:.18s ease}.primary{color:white;background:linear-gradient(180deg,#5ac4e4,#218fba);border:2px solid white;box-shadow:0 3px 0 #14749d,0 8px 17px rgba(22,104,140,.19)}.primary:hover{transform:translateY(-1px);filter:brightness(1.04)}.ghost{color:#3c7891;background:rgba(255,255,255,.72);border:1px solid rgba(39,118,151,.18)}.ghost:hover{background:white}.compact{padding:8px 12px;border-radius:10px;font-size:12px}main{padding:40px 0 72px}.hero{min-height:620px;display:grid;grid-template-columns:1.05fr .95fr;gap:52px;align-items:center}.eyebrow{color:#168ab7;font-size:11px;letter-spacing:2px;font-weight:900}.hero h1{font-size:clamp(48px,6vw,82px);line-height:.98;margin:13px 0 20px;letter-spacing:-3px;color:#174f70;text-shadow:0 2px white}.gradient-text{color:#e79926;text-shadow:0 2px #fff7c6}.hero p{max-width:680px;color:#426f84;font-size:18px;line-height:1.7}.hero-actions{display:flex;gap:12px;margin-top:28px}.stats{display:flex;gap:18px;margin-top:38px;flex-wrap:wrap}.stat{min-width:120px;padding:12px 15px;border-radius:14px;background:rgba(255,255,255,.68);border:1px solid rgba(255,255,255,.88);box-shadow:0 8px 18px rgba(33,117,150,.09)}.stat strong{font-size:22px;display:block;color:#186e96}.stat span{color:#6a8a99;font-size:11px}.hero-card{position:relative;min-height:455px;border:4px solid rgba(255,255,255,.88);background:linear-gradient(180deg,#a8e7f7 0,#ddf8ff 47%,#5dc1dd 48%,#238daf 100%);border-radius:34px;overflow:hidden;box-shadow:0 22px 60px rgba(15,97,133,.23),inset 0 0 0 2px rgba(33,126,163,.14)}.hero-card:before{content:'';position:absolute;left:8%;right:8%;bottom:74px;height:130px;background:radial-gradient(ellipse at 22% 75%,#5baa58 0 25%,transparent 26%),radial-gradient(ellipse at 40% 85%,#4b9547 0 29%,transparent 30%),radial-gradient(ellipse at 72% 78%,#62ae58 0 25%,transparent 26%)}.island{position:absolute;left:50%;top:70px;transform:translateX(-50%);width:235px;height:235px;border-radius:50%;background:radial-gradient(circle at 42% 36%,#fff4b0 0 9%,#f4c85b 10% 17%,#73b965 18% 34%,#3588a7 35% 52%,#1e6e9b 53% 61%,rgba(255,255,255,.85) 62% 64%,transparent 65%);filter:drop-shadow(0 10px 15px rgba(31,102,130,.16))}.island:after{content:'✦';position:absolute;inset:0;display:grid;place-items:center;color:white;font-size:52px;text-shadow:0 3px 10px #197da6}.hero-panel{position:absolute;left:24px;right:24px;bottom:24px;padding:18px 20px;background:rgba(255,253,242,.93);border:2px solid white;border-radius:18px;box-shadow:0 8px 22px rgba(21,96,127,.18)}.hero-panel strong{display:block;margin:4px 0 5px;color:#225f7b}.hero-panel p{font-size:13px;margin:0;color:#628394;line-height:1.5}.section-head{display:flex;justify-content:space-between;gap:20px;align-items:end;margin-bottom:22px}.section-head h1{font-size:43px;margin:5px 0 0;color:#174f70;text-shadow:0 2px white;letter-spacing:-1.5px}.section-head p{color:#4a7385;max-width:650px;margin:0}.shop-account-banner,.shop-lock{display:flex;align-items:center;justify-content:space-between;gap:24px;padding:22px 24px;margin-bottom:20px;border:3px solid rgba(255,255,255,.9);border-radius:21px;background:linear-gradient(180deg,rgba(255,253,241,.95),rgba(248,244,218,.93));box-shadow:0 10px 26px rgba(25,103,135,.14)}.shop-account-banner h2,.shop-lock h2{margin:4px 0;color:#315e72}.shop-account-banner p,.shop-lock p{color:#718b96;margin:0}.balance-panel{min-width:175px;text-align:right}.balance-panel small,.balance-panel span{display:block;color:#8197a0}.balance-panel strong{font-size:34px;color:#d49325}.lock-icon{width:60px;height:60px;flex:0 0 60px;display:grid;place-items:center;border-radius:50%;color:white;background:linear-gradient(145deg,#68d1e8,#2b94bc);border:3px solid white;box-shadow:0 3px 0 #1c799f}.lock-actions{display:flex;gap:9px}.shop-tools{display:flex;gap:12px;align-items:center;margin:20px 0;flex-wrap:wrap}.search{flex:1;min-width:260px;position:relative}.search input{width:100%;padding:13px 16px 13px 42px;color:#315d72;background:rgba(255,255,255,.9);border:2px solid rgba(255,255,255,.95);border-bottom-color:rgba(24,117,154,.2);border-radius:14px;outline:0;box-shadow:0 6px 18px rgba(26,105,138,.08)}.search input:focus{border-color:#66c9e6}.search span{position:absolute;left:15px;top:11px;color:#4593b1;font-size:20px}.filters{display:flex;gap:7px;flex-wrap:wrap}.filter{border:1px solid rgba(31,112,145,.17);color:#47758a;background:rgba(255,255,255,.73);padding:9px 12px;border-radius:11px;cursor:pointer;font-weight:800}.filter:hover,.filter.active{color:white;background:linear-gradient(180deg,#65c8e5,#2b99c0);border-color:white;box-shadow:0 3px 0 #1b789d}.shop-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(235px,1fr));gap:15px}.shop-card{min-height:325px;display:flex;flex-direction:column;overflow:hidden;border:3px solid rgba(255,255,255,.92);border-radius:20px;background:linear-gradient(180deg,var(--paper),#fff7db);box-shadow:0 11px 25px rgba(22,96,127,.13);transition:.18s ease}.shop-card:hover{transform:translateY(-4px) scale(1.006);box-shadow:0 17px 34px rgba(20,91,121,.2)}.item-art{height:178px;position:relative;display:grid;place-items:center;background:radial-gradient(circle at 50% 40%,#fff 0 28%,#e7f8ff 55%,#bfe9f7 100%);border-bottom:1px solid #d4e7e8}.item-picture{width:132px;height:132px;display:grid;place-items:center;border-radius:22px;background:rgba(255,255,255,.72);border:2px solid rgba(255,255,255,.95);box-shadow:inset 0 0 0 1px rgba(46,132,165,.09),0 7px 18px rgba(37,117,146,.12)}.item-picture img{width:118px;height:118px;object-fit:contain;image-rendering:auto}.item-id{position:absolute;right:10px;bottom:9px;color:#6b95a5;font-family:Consolas,monospace;font-size:10px;background:rgba(255,255,255,.72);padding:4px 6px;border-radius:7px}.ribbon{position:absolute;left:9px;top:9px;padding:5px 8px;border-radius:9px;color:white;font-size:9px;font-weight:900;letter-spacing:1px}.ribbon.hot{background:#df6b48}.ribbon.new{background:#45a96f}.item-copy{padding:15px;flex:1;display:flex;flex-direction:column}.item-meta{display:flex;justify-content:space-between;color:#2792b9;font-size:10px;letter-spacing:.8px;text-transform:uppercase;font-weight:900}.item-copy h3{font-size:15px;line-height:1.35;margin:9px 0 18px;color:#345c6f}.item-bottom{margin-top:auto;display:flex;align-items:center;justify-content:space-between;gap:10px}.price b{font-size:22px;color:#d28b1f}.price span{font-size:10px;color:#81949c;margin-left:4px}.buy-button{border:2px solid white;padding:9px 14px;border-radius:11px;background:linear-gradient(180deg,#f7c858,#e69b26);box-shadow:0 3px 0 #b9781b;color:white;font-weight:900;cursor:pointer;text-shadow:0 1px rgba(119,72,8,.28)}.buy-button:hover:not(:disabled){filter:brightness(1.05);transform:translateY(-1px)}.buy-button:disabled{opacity:.38;cursor:not-allowed}.auth-wrap{width:min(1080px,100%);margin:28px auto 0;display:grid;grid-template-columns:.92fr 1.08fr;border:4px solid rgba(255,255,255,.9);border-radius:28px;overflow:hidden;background:rgba(255,253,244,.95);box-shadow:0 22px 60px rgba(18,92,124,.2)}.auth-side{padding:48px;background:linear-gradient(160deg,#bdefff,#71cae5 60%,#2a99bd)}.auth-side h2{font-size:36px;margin:12px 0;color:#185a7b;text-shadow:0 1px white}.auth-side p{color:#346e85;line-height:1.65}.auth-list{margin-top:28px;display:grid;gap:12px;color:#245e78;font-size:13px}.auth-list div{display:flex;gap:10px}.auth-list b{color:#208857}.auth-form{padding:48px}.auth-form h1{margin:0 0 6px;color:#2d5c72}.auth-form>p{color:#78909b;margin:0 0 26px}.field{margin-bottom:14px}.field label{display:block;font-size:11px;color:#6c8794;font-weight:900;margin-bottom:7px;text-transform:uppercase;letter-spacing:.8px}.field input{width:100%;padding:13px 14px;color:#315c70;background:white;border:1px solid #c9dfe5;border-radius:11px;outline:0}.field input:focus{border-color:#4fbadc;box-shadow:0 0 0 3px rgba(67,184,218,.12)}.form-row{display:grid;grid-template-columns:1fr 1fr;gap:12px}.form-submit{width:100%;margin-top:8px;padding:13px 16px}.form-note{font-size:12px;color:#78909b;margin-top:16px;text-align:center}.alert{display:none;margin-bottom:16px;padding:11px 13px;border-radius:10px;font-size:13px}.alert.show{display:block}.alert.error{color:#8d3333;background:#ffe4e4;border:1px solid #efb3b3}.alert.success{color:#286d46;background:#e4f8eb;border:1px solid #aedbbf}.toast{position:fixed;right:24px;bottom:24px;z-index:50;width:min(390px,calc(100% - 48px));transform:translateY(20px);opacity:0;pointer-events:none;padding:15px 17px;border:3px solid white;border-radius:15px;background:#fff9e7;color:#315d72;box-shadow:0 18px 50px rgba(18,91,122,.3);transition:.2s ease}.toast.show{opacity:1;transform:translateY(0)}.toast.good{border-color:#92d9ae}.toast.bad{border-color:#eda6a6}footer{padding:25px 0 38px;color:rgba(255,255,255,.86);font-size:12px;display:flex;justify-content:space-between;gap:20px;text-shadow:0 1px rgba(10,75,104,.2)}
@media(max-width:900px){.nav-links{display:none}.account-chip>div:nth-child(2),.mini-balance{display:none}.hero{grid-template-columns:1fr}.hero-card{min-height:370px}.auth-wrap{grid-template-columns:1fr}.auth-side{display:none}.shop-account-banner,.shop-lock{align-items:flex-start;flex-direction:column}.balance-panel{text-align:left}}
@media(max-width:560px){.shell{width:min(100% - 20px,1460px)}nav{height:70px;margin-top:8px}.brand>div:last-child{display:none}main{padding-top:25px}.hero{min-height:auto}.hero h1{font-size:49px}.hero-card{min-height:330px}.auth-form{padding:28px 20px}.form-row{grid-template-columns:1fr}.shop-grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<div class='shell'>
<nav>
<a class='brand' href='/'><div class='brand-mark'>W</div><div>Wonderland Online<span>PRIVATE SERVER</span></div></a>
<div class='nav-links'><a class='@@ACTIVE_HOME@@' href='/'>Home</a><a class='@@ACTIVE_SHOP@@' href='/shop'>Item Mall</a><a class='@@ACTIVE_REGISTER@@' href='/register'>Create account</a></div>
<div class='nav-right'>@@ACCOUNT_AREA@@</div>
</nav>
<main>
<section style='display:@@HOME_DISPLAY@@'>
<div class='hero'><div><span class='eyebrow'>THE ISLAND AWAITS</span><h1>Adventure lives in <span class='gradient-text'>Wonderland.</span></h1><p>Create your account, enter the Rhode Island world and manage your Item Mall from one bright, classic-inspired portal.</p><div class='hero-actions'>@@HOME_ACTIONS@@</div><div class='stats'><div class='stat'><strong>@@ONLINE_COUNT@@</strong><span>Players online</span></div><div class='stat'><strong>@@CATALOG_COUNT@@</strong><span>Item Mall listings</span></div><div class='stat'><strong>6414</strong><span>Game port</span></div></div></div><div class='hero-card'><div class='island'></div><div class='hero-panel'><span class='eyebrow'>WONDERLAND PRIVATE SERVER</span><strong>Your adventure account, all in one place.</strong><p>The same account works in game and on the portal. Item Mall purchases remain locked to your own User ID.</p></div></div></div>
</section>
<section style='display:@@SHOP_DISPLAY@@'>
<div class='section-head'><div><span class='eyebrow'>WONDERLAND ITEM MALL</span><h1>Island Market</h1></div><p>Real Wonderland item artwork is loaded from the local wiki-image cache. Sign in and keep your character online to receive purchases instantly.</p></div>
@@SHOP_GATE@@
<div class='shop-tools'><div class='search'><span>⌕</span><input id='shopSearch' type='search' placeholder='Search the Item Mall...' oninput='filterItems()'></div><div class='filters'>@@CATEGORY_BUTTONS@@</div></div>
<div id='shopGrid' class='shop-grid'>@@ITEM_CARDS@@</div>
</section>
<section style='display:@@REGISTER_DISPLAY@@'>
<div class='auth-wrap'><div class='auth-side'><span class='eyebrow'>NEW ADVENTURER</span><h2>Begin your Wonderland story.</h2><p>Create the account you will use both in the game client and on this portal.</p><div class='auth-list'><div><b>✓</b><span>Your username is checked before it is created.</span></div><div><b>✓</b><span>Credentials work in both the Rhode Island client and portal.</span></div><div><b>✓</b><span>Item Mall purchases are tied to your account.</span></div></div></div><form class='auth-form' id='registerForm' onsubmit='registerAccount(event)'><span class='eyebrow'>CREATE ACCOUNT</span><h1>Join Wonderland</h1><p>Choose your adventurer account credentials.</p><div id='registerAlert' class='alert'></div><div class='field'><label>Username</label><input name='username' minlength='3' maxlength='20' pattern='[A-Za-z0-9_]+' autocomplete='username' required placeholder='Choose a username'></div><div class='field'><label>Email</label><input name='email' type='email' maxlength='120' autocomplete='email' required placeholder='you@example.com'></div><div class='form-row'><div class='field'><label>Password</label><input name='password' type='password' minlength='4' maxlength='64' autocomplete='new-password' required placeholder='Password'></div><div class='field'><label>Confirm password</label><input name='confirmPassword' type='password' minlength='4' maxlength='64' autocomplete='new-password' required placeholder='Repeat password'></div></div><button class='primary form-submit' type='submit'>Create account</button><div class='form-note'>Already registered? <a href='/login' style='color:#1889b2;font-weight:800'>Sign in here</a></div></form></div>
</section>
<section style='display:@@LOGIN_DISPLAY@@'>
<div class='auth-wrap'><div class='auth-side'><span class='eyebrow'>WELCOME BACK</span><h2>Return to your adventure.</h2><p>Sign in with your Wonderland account before entering the Item Mall.</p><div class='auth-list'><div><b>✓</b><span>See your current IM Point balance.</span></div><div><b>✓</b><span>Purchases go only to your own account.</span></div><div><b>✓</b><span>Items deliver while your character is online.</span></div></div></div><form class='auth-form' id='loginForm' onsubmit='loginAccount(event)'><span class='eyebrow'>ACCOUNT LOGIN</span><h1>Sign in</h1><p>Use the same username and password you use in game.</p><div id='loginAlert' class='alert'></div><div class='field'><label>Username</label><input name='username' autocomplete='username' required placeholder='Username'></div><div class='field'><label>Password</label><input name='password' type='password' autocomplete='current-password' required placeholder='Password'></div><button class='primary form-submit' type='submit'>Sign in to portal</button><div class='form-note'>Need an account? <a href='/register' style='color:#1889b2;font-weight:800'>Create one</a></div></form></div>
</section>
</main>
<footer><span>Wonderland Online Private Server Portal</span><span>Game: 127.0.0.1:6414 · Portal: :@@PORT@@</span></footer>
</div>
<div id='toast' class='toast'></div>
<script>
let activeFilter='all';
function formBody(form){return new URLSearchParams(new FormData(form));}
async function portalPost(url,body){const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8','X-WLO-Portal':'1'},body:body});let data;try{data=await response.json();}catch{data={success:false,error:'Invalid server response'};}if(!response.ok&&!data.error)data.error='Request failed';return data;}
function setAlert(id,text,good){const el=document.getElementById(id);if(!el)return;el.className='alert show '+(good?'success':'error');el.textContent=text;}
function toast(text,good){const el=document.getElementById('toast');el.textContent=text;el.className='toast show '+(good?'good':'bad');clearTimeout(window.__toastTimer);window.__toastTimer=setTimeout(()=>el.className='toast',3600);}
async function registerAccount(e){e.preventDefault();const form=e.target;const p=form.password.value,c=form.confirmPassword.value;if(p!==c){setAlert('registerAlert','Passwords do not match.',false);return;}const btn=form.querySelector('button[type=submit]');btn.disabled=true;btn.textContent='Creating account...';try{const d=await portalPost('/register',formBody(form));if(d.success){setAlert('registerAlert',d.message||'Account created.',true);setTimeout(()=>location.href='/shop',700);}else setAlert('registerAlert',d.error||d.message||'Registration failed.',false);}catch{setAlert('registerAlert','Could not reach the portal server.',false);}finally{btn.disabled=false;btn.textContent='Create account';}}
async function loginAccount(e){e.preventDefault();const form=e.target;const btn=form.querySelector('button[type=submit]');btn.disabled=true;btn.textContent='Signing in...';try{const d=await portalPost('/api/login',formBody(form));if(d.success){setAlert('loginAlert','Signed in. Opening Item Mall...',true);setTimeout(()=>location.href='/shop',450);}else setAlert('loginAlert',d.error||'Sign in failed.',false);}catch{setAlert('loginAlert','Could not reach the portal server.',false);}finally{btn.disabled=false;btn.textContent='Sign in to portal';}}
async function logout(){try{await portalPost('/api/logout','');}finally{location.href='/';}}
async function buyItem(btn){if(btn.disabled)return;const id=btn.dataset.id,count=btn.dataset.count,name=btn.dataset.name,cost=btn.dataset.cost;if(!confirm('Purchase '+name+' x'+count+' for '+cost+' IM Points?'))return;const original=btn.textContent;btn.disabled=true;btn.textContent='Buying...';try{const d=await portalPost('/api/buy',new URLSearchParams({item:id,count:count}));if(d.success){toast(d.message||'Purchase complete.',true);if(document.getElementById('navPoints'))document.getElementById('navPoints').textContent=Number(d.points||0).toLocaleString();if(document.getElementById('shopPoints'))document.getElementById('shopPoints').textContent=Number(d.points||0).toLocaleString();}else toast(d.error||'Purchase failed.',false);}catch{toast('Could not reach the Item Mall service.',false);}finally{btn.disabled=false;btn.textContent=original;}}
function setFilter(btn){document.querySelectorAll('.filter').forEach(x=>x.classList.remove('active'));btn.classList.add('active');activeFilter=btn.dataset.filter||'all';filterItems();}
function filterItems(){const q=(document.getElementById('shopSearch')?.value||'').toLowerCase().trim();document.querySelectorAll('.shop-card').forEach(card=>{const cat=card.dataset.category||'',name=card.dataset.name||'';card.style.display=((activeFilter==='all'||cat===activeFilter)&&(!q||name.includes(q)))?'flex':'none';});}
async function refreshSession(){try{const r=await fetch('/api/session',{cache:'no-store'});const d=await r.json();if(!d.authenticated)return;if(document.getElementById('navPoints'))document.getElementById('navPoints').textContent=Number(d.points||0).toLocaleString();if(document.getElementById('shopPoints'))document.getElementById('shopPoints').textContent=Number(d.points||0).toLocaleString();const status=document.getElementById('gameStatus');if(status)status.textContent=d.online?('Online as '+d.character+' — purchases deliver instantly.'):'Game offline — log into Wonderland Online before purchasing.';}catch{}}
setInterval(refreshSession,15000);
</script>
</body>
</html>";
        }
    }
}

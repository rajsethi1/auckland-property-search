<?php
// Shared helpers for the site's API: JSON replies, JSON files under data/ (locked while changed),
// the sign-in session, and failed-login limits. data/ is closed to the web by its .htaccess.
declare(strict_types=1);

const DATA_DIR = __DIR__ . '/data';
const SESSION_DAYS = 30;

session_name('aps_session');
session_set_cookie_params([
    'lifetime' => SESSION_DAYS * 86400, 'path' => '/', 'httponly' => true, 'samesite' => 'Lax',
    'secure' => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
]);
ini_set('session.gc_maxlifetime', (string)(SESSION_DAYS * 86400));
session_start();
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex');

function out($data, int $code = 200): void {
    http_response_code($code);
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode($data, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);
    exit;
}
function fail(int $code, string $msg): void { out(['error' => $msg], $code); }

// POST body as an array. The custom header can't be sent cross-site without CORS, which blocks forged requests.
function body(): array {
    if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') fail(405, 'POST only');
    if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') !== 'aps') fail(400, 'Bad request');
    $in = json_decode(file_get_contents('php://input') ?: '', true);
    return is_array($in) ? $in : [];
}

// Read (and with $write, change) data/<name> under a file lock. $fn gets the decoded array by reference.
function with_json(string $name, callable $fn, bool $write = true) {
    if (!is_dir(DATA_DIR) && !mkdir(DATA_DIR, 0750, true)) fail(500, 'Storage unavailable');
    $fp = fopen(DATA_DIR . '/' . $name, 'c+');
    if (!$fp) fail(500, 'Storage unavailable');
    flock($fp, $write ? LOCK_EX : LOCK_SH);
    $d = json_decode(stream_get_contents($fp) ?: '{}', true);
    if (!is_array($d)) $d = [];
    $before = $d;
    $res = $fn($d);
    if ($write && $d !== $before) {
        ftruncate($fp, 0); rewind($fp);
        fwrite($fp, json_encode($d, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
        fflush($fp);
    }
    flock($fp, LOCK_UN); fclose($fp);
    return $res;
}
function read_json(string $name): array { return with_json($name, function (&$d) { return $d; }, false); }

function clean_username($s): string { $s = strtolower(trim((string)$s)); return preg_match('/^[a-z0-9._-]{3,30}$/', $s) ? $s : ''; }
function clean_text($s, int $max): string { return mb_substr(trim(is_string($s) ? $s : ''), 0, $max); }
function check_password(string $pw): void { if (mb_strlen($pw) < 8) fail(400, 'Passwords need at least 8 characters'); }
function random_code(int $len): string { $a = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; $s = ''; for ($i = 0; $i < $len; $i++) $s .= $a[random_int(0, strlen($a) - 1)]; return $s; }

// The signed-in user, re-checked against users.json so a removed account is signed out on its next request.
function current_user(): ?array {
    $u = $_SESSION['user'] ?? null;
    if (!$u) return null;
    $rec = read_json('users.json')['users'][$u] ?? null;
    if (!$rec) { $_SESSION = []; return null; }
    return ['username' => $u, 'name' => $rec['name'] ?? $u, 'admin' => !empty($rec['admin'])];
}
function require_user(): array { $u = current_user(); if (!$u) fail(401, 'Please sign in'); return $u; }
function require_admin(): array { $u = require_user(); if (!$u['admin']) fail(403, 'Admins only'); return $u; }
function sign_in(string $u): void { session_regenerate_id(true); $_SESSION['user'] = $u; }

// Failed sign-ins: at most 10 per IP address and per username in 15 minutes.
function limited(string $key): bool {
    $t = time() - 900;
    return with_json('attempts.json', function (&$d) use ($key, $t) {
        foreach ($d as $k => $list) { $d[$k] = array_values(array_filter($list, fn($x) => $x > $t)); if (!$d[$k]) unset($d[$k]); }
        return count($d[$key] ?? []) >= 10;
    });
}
function note_fail(string $key): void { with_json('attempts.json', function (&$d) use ($key) { $d[$key][] = time(); }); }

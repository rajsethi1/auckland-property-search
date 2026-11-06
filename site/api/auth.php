<?php
// Sign in / out, first-admin setup, sign-up with an invite code, and changing your own password.
// GET -> {user, setup}: setup is true while no account exists yet (the first sign-up becomes the admin).
require __DIR__ . '/common.php';

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'GET') out(['user' => current_user(), 'setup' => empty(read_json('users.json')['users'])]);

$in = body();
$ip = $_SERVER['REMOTE_ADDR'] ?? 'unknown';
$op = $in['op'] ?? '';

if ($op === 'login') {
    $u = clean_username($in['username'] ?? '');
    $pw = (string)($in['password'] ?? '');
    if (limited("ip:$ip") || ($u && limited("user:$u"))) fail(429, 'Too many attempts. Wait 15 minutes and try again.');
    $rec = $u ? (read_json('users.json')['users'][$u] ?? null) : null;
    if (!$rec || !password_verify($pw, $rec['hash'] ?? '')) {
        note_fail("ip:$ip"); if ($u) note_fail("user:$u");
        fail(401, 'Wrong username or password');
    }
    sign_in($u);
    with_json('users.json', function (&$d) use ($u) { $d['users'][$u]['last'] = gmdate('c'); });
    out(['user' => current_user()]);
}

if ($op === 'logout') { $_SESSION = []; session_destroy(); out(['user' => null]); }

if ($op === 'setup' || $op === 'register') {
    if (limited("ip:$ip")) fail(429, 'Too many attempts. Wait 15 minutes and try again.');
    $u = clean_username($in['username'] ?? '');
    $name = clean_text($in['name'] ?? '', 60);
    $pw = (string)($in['password'] ?? '');
    if (!$u) fail(400, 'Usernames are 3-30 characters: letters, numbers, dots, dashes or underscores');
    if ($name === '') $name = $u;
    check_password($pw);
    $code = strtoupper(trim((string)($in['invite'] ?? '')));
    $err = with_json('users.json', function (&$d) use ($op, $u, $name, $pw, $code) {
        $d += ['users' => [], 'invite' => ['code' => '', 'enabled' => false]];
        if ($op === 'setup') {
            if ($d['users']) return 'The admin account already exists. Sign in instead.';
            $d['invite'] = ['code' => random_code(8), 'enabled' => true];
        } else {
            $inv = $d['invite'];
            if (!$inv['enabled'] || $inv['code'] === '' || !hash_equals($inv['code'], $code)) return 'That invite code is not valid';
            if (isset($d['users'][$u])) return 'That username is taken';
        }
        $d['users'][$u] = ['name' => $name, 'hash' => password_hash($pw, PASSWORD_DEFAULT), 'admin' => $op === 'setup', 'created' => gmdate('c'), 'last' => gmdate('c')];
        return null;
    });
    if ($err) { note_fail("ip:$ip"); fail(400, $err); }
    sign_in($u);
    out(['user' => current_user()]);
}

if ($op === 'password') {
    $me = require_user();
    $old = (string)($in['old'] ?? ''); $new = (string)($in['new'] ?? '');
    check_password($new);
    $ok = with_json('users.json', function (&$d) use ($me, $old, $new) {
        $rec = &$d['users'][$me['username']];
        if (!password_verify($old, $rec['hash'] ?? '')) return false;
        $rec['hash'] = password_hash($new, PASSWORD_DEFAULT);
        return true;
    });
    if (!$ok) fail(400, 'Your current password is not right');
    out(['ok' => true]);
}

fail(400, 'Unknown action');

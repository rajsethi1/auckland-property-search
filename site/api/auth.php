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
    $email = clean_email($in['email'] ?? '');
    if (trim((string)($in['email'] ?? '')) !== '' && !$email) fail(400, 'That email address does not look right');
    $err = with_json('users.json', function (&$d) use ($op, $u, $name, $pw, $code, $email) {
        $d += ['users' => [], 'invite' => ['code' => '', 'enabled' => false]];
        if ($op === 'setup') {
            if ($d['users']) return 'The admin account already exists. Sign in instead.';
            $d['invite'] = ['code' => random_code(8), 'enabled' => true];
        } else {
            $inv = $d['invite'];
            if (!$inv['enabled'] || $inv['code'] === '' || !hash_equals($inv['code'], $code)) return 'That invite code is not valid';
            if (isset($d['users'][$u])) return 'That username is taken';
        }
        $d['users'][$u] = ['name' => $name, 'hash' => password_hash($pw, PASSWORD_DEFAULT), 'admin' => $op === 'setup', 'created' => gmdate('c'), 'last' => gmdate('c'), 'email' => $email];
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

if ($op === 'email') {
    $me = require_user();
    $email = clean_email($in['email'] ?? '');
    if (trim((string)($in['email'] ?? '')) !== '' && !$email) fail(400, 'That email address does not look right');
    with_json('users.json', function (&$d) use ($me, $email) { $d['users'][$me['username']]['email'] = $email; });
    out(['user' => current_user()]);
}

// Forgot password: emails a one-hour reset link when the account has an email address, and always
// flags the request on the Admin page. The reply never says whether the account exists.
if ($op === 'forgot') {
    if (limited("forgot:$ip")) fail(429, 'Too many requests. Wait 15 minutes and try again.');
    note_fail("forgot:$ip"); note_fail("forgot:$ip"); // at most 5 requests per 15 minutes
    $who = strtolower(trim((string)($in['who'] ?? '')));
    $token = bin2hex(random_bytes(24));
    $to = with_json('users.json', function (&$d) use ($who, $token) {
        if (empty($d['users'])) return null;
        foreach ($d['users'] as $u => &$r) {
            if ($who === '' || ($u !== $who && ($r['email'] ?? '') !== $who)) continue;
            $r['reset_asked'] = gmdate('c');
            if (empty($r['email'])) return null;
            $r['reset'] = ['hash' => hash('sha256', $token), 'until' => time() + 3600];
            return ['email' => $r['email'], 'name' => $r['name'] ?? $u, 'username' => $u];
        }
        return null;
    });
    if ($to) {
        $host = preg_replace('/[^a-z0-9.-]/i', '', (string)($_SERVER['SERVER_NAME'] ?? ''));
        $link = "https://$host/#/reset?t=$token";
        $body = "Hi {$to['name']},\r\n\r\nSomeone (hopefully you) asked to reset the PropertyHunte password for username {$to['username']}.\r\n\r\n"
              . "Choose a new password here (the link works for one hour):\r\n$link\r\n\r\nIf you didn't ask for this, ignore this email; your password stays the same.\r\n";
        @mail($to['email'], 'Reset your PropertyHunte password', $body, "From: PropertyHunte <noreply@$host>\r\nContent-Type: text/plain; charset=utf-8");
    }
    out(['ok' => true]);
}

if ($op === 'reset') {
    if (limited("ip:$ip")) fail(429, 'Too many attempts. Wait 15 minutes and try again.');
    $t = (string)($in['token'] ?? ''); $pw = (string)($in['password'] ?? '');
    check_password($pw);
    $u = preg_match('/^[a-f0-9]{48}$/', $t) ? with_json('users.json', function (&$d) use ($t, $pw) {
        if (empty($d['users'])) return null;
        foreach ($d['users'] as $u => &$r) {
            $rs = $r['reset'] ?? null;
            if ($rs && $rs['until'] > time() && hash_equals($rs['hash'], hash('sha256', $t))) {
                $r['hash'] = password_hash($pw, PASSWORD_DEFAULT); unset($r['reset'], $r['reset_asked']);
                return $u;
            }
        }
        return null;
    }) : null;
    if (!$u) { note_fail("ip:$ip"); fail(400, 'This reset link has expired or was already used. Ask for a new one.'); }
    sign_in($u);
    out(['user' => current_user()]);
}

fail(400, 'Unknown action');

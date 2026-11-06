<?php
// Admin only. GET -> {users: [...], invite: {code, enabled}}.
// POST op: invite_new | invite_enabled {enabled} | reset {username} -> {password} | delete {username} | admin {username, on}
require __DIR__ . '/common.php';
$me = require_admin();

function listing(): array {
    $d = read_json('users.json');
    $users = [];
    foreach ($d['users'] ?? [] as $u => $r) $users[] = ['username' => $u, 'name' => $r['name'] ?? $u, 'admin' => !empty($r['admin']), 'created' => $r['created'] ?? '', 'last' => $r['last'] ?? ''];
    usort($users, fn($a, $b) => strcmp($a['username'], $b['username']));
    return ['users' => $users, 'invite' => $d['invite'] ?? ['code' => '', 'enabled' => false]];
}

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'GET') out(listing());

$in = body();
$op = $in['op'] ?? '';
$u = clean_username($in['username'] ?? '');
$extra = [];

$err = with_json('users.json', function (&$d) use ($op, $u, $me, $in, &$extra) {
    $d += ['users' => [], 'invite' => ['code' => '', 'enabled' => false]];
    if ($op === 'invite_new') { $d['invite'] = ['code' => random_code(8), 'enabled' => true]; return null; }
    if ($op === 'invite_enabled') { $d['invite']['enabled'] = !empty($in['enabled']); return null; }
    if (!$u || !isset($d['users'][$u])) return 'No such user';
    if ($op === 'reset') {
        $pw = random_code(10);
        $d['users'][$u]['hash'] = password_hash($pw, PASSWORD_DEFAULT);
        $extra = ['password' => $pw];
        return null;
    }
    if ($u === $me['username']) return "You can't remove or demote your own account";
    if ($op === 'delete') { unset($d['users'][$u]); return null; }
    if ($op === 'admin') { $d['users'][$u]['admin'] = !empty($in['on']); return null; }
    return 'Unknown action';
});
if ($err) fail(400, $err);
// A removed user's saved lists go too.
if ($op === 'delete') with_json('lists.json', function (&$d) use ($u) { unset($d['users'][$u]); });
out(listing() + $extra);

<?php
// Each signed-in person's saved lists, all kept in data/lists.json:
//   { "users": { "<username>": { "shortlist": { "<listing id>": {address, url, suburb, at, lists: [list ids]} }, "lists": { "<list id>": {name, at} } } } }
// GET returns your store. POST {op: "set"|"delete", col: "shortlist"|"lists", id, data} changes one entry and returns your store.
require __DIR__ . '/common.php';
$user = require_user();
$me = $user['username'];
// Lists saved before sign-in existed (one shared store) move to the first admin who opens their lists.
if ($user['admin']) with_json('lists.json', function (&$d) use ($me) {
    if (!isset($d['shortlist']) && !isset($d['lists'])) return;
    if (empty($d['users'][$me]['shortlist']) && empty($d['users'][$me]['lists'])) $d['users'][$me] = ['shortlist' => $d['shortlist'] ?? [], 'lists' => $d['lists'] ?? []];
    unset($d['shortlist'], $d['lists']);
});

function clean_entry(string $col, $d): array {
    if (!is_array($d)) $d = [];
    if ($col === 'lists') return ['name' => clean_text($d['name'] ?? '', 40) ?: 'Untitled', 'at' => clean_text($d['at'] ?? '', 40)];
    $url = clean_text($d['url'] ?? '', 300);
    $ids = array_values(array_filter(is_array($d['lists'] ?? null) ? $d['lists'] : [], fn($x) => is_string($x) && preg_match('/^[A-Za-z0-9_-]{1,40}$/', $x)));
    return ['address' => clean_text($d['address'] ?? '', 200), 'url' => preg_match('#^https://#', $url) ? $url : '',
        'suburb' => clean_text($d['suburb'] ?? '', 80), 'at' => clean_text($d['at'] ?? '', 40), 'lists' => array_slice($ids, 0, 20)];
}
// Objects, not arrays, even when empty, so the page can always use Object.entries().
function mine(array $d, string $me): array { $s = $d['users'][$me] ?? []; return ['shortlist' => (object)($s['shortlist'] ?? []), 'lists' => (object)($s['lists'] ?? [])]; }

if (($_SERVER['REQUEST_METHOD'] ?? '') === 'GET') out(mine(read_json('lists.json'), $me));

$in = body();
$op = $in['op'] ?? ''; $col = $in['col'] ?? ''; $id = (string)($in['id'] ?? '');
if (!in_array($op, ['set', 'delete'], true) || !in_array($col, ['shortlist', 'lists'], true) || !preg_match('/^[A-Za-z0-9_-]{1,40}$/', $id)) fail(400, 'Bad request');
$res = with_json('lists.json', function (&$d) use ($me, $op, $col, $id, $in) {
    $d['users'][$me] = ($d['users'][$me] ?? []) + ['shortlist' => [], 'lists' => []];
    $s = &$d['users'][$me][$col];
    if ($op === 'delete') unset($s[$id]);
    elseif (count($s) >= 2000 && !isset($s[$id])) return 'Too many saved items';
    else $s[$id] = clean_entry($col, $in['data'] ?? []);
    return mine($d, $me);
});
if (is_string($res)) fail(400, $res);
out($res);

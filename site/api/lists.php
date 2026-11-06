<?php
// Shared saved lists for the site, kept in data/lists.json beside this file:
//   { "shortlist": { "<listing id>": {address, url, suburb, at, lists: [list ids]} }, "lists": { "<list id>": {name, at} } }
// GET returns the whole store. POST {op: "set"|"delete", col: "shortlist"|"lists", id, data} changes one entry and
// returns the store. The site's password (hPanel > Password protect directories) also covers this file.
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex');

function fail($code, $msg) { http_response_code($code); echo json_encode(['error' => $msg]); exit; }
function str_field($v, $max) { return mb_substr(is_string($v) ? $v : '', 0, $max); }
function clean_entry($col, $d) {
    if (!is_array($d)) $d = [];
    if ($col === 'lists') return ['name' => str_field($d['name'] ?? '', 40) ?: 'Untitled', 'at' => str_field($d['at'] ?? '', 40)];
    $url = str_field($d['url'] ?? '', 300);
    $ids = array_values(array_filter(is_array($d['lists'] ?? null) ? $d['lists'] : [], fn($x) => is_string($x) && preg_match('/^[A-Za-z0-9_-]{1,40}$/', $x)));
    return [
        'address' => str_field($d['address'] ?? '', 200),
        'url' => preg_match('#^https://#', $url) ? $url : '',
        'suburb' => str_field($d['suburb'] ?? '', 80),
        'at' => str_field($d['at'] ?? '', 40),
        'lists' => array_slice($ids, 0, 20),
    ];
}

$file = __DIR__ . '/data/lists.json';
if (!is_dir(dirname($file)) && !mkdir(dirname($file), 0750, true)) fail(500, 'storage');
$fp = fopen($file, 'c+');
if (!$fp) fail(500, 'storage');
$post = $_SERVER['REQUEST_METHOD'] === 'POST';
flock($fp, $post ? LOCK_EX : LOCK_SH);
$store = json_decode(stream_get_contents($fp) ?: '{}', true);
if (!is_array($store)) $store = [];
$store += ['shortlist' => [], 'lists' => []];

if ($post) {
    $in = json_decode(file_get_contents('php://input'), true);
    $op = $in['op'] ?? ''; $col = $in['col'] ?? ''; $id = (string)($in['id'] ?? '');
    if (!in_array($op, ['set', 'delete'], true) || !in_array($col, ['shortlist', 'lists'], true) || !preg_match('/^[A-Za-z0-9_-]{1,40}$/', $id)) {
        flock($fp, LOCK_UN); fail(400, 'bad request');
    }
    if ($op === 'delete') unset($store[$col][$id]);
    elseif (count($store[$col]) >= 5000 && !isset($store[$col][$id])) { flock($fp, LOCK_UN); fail(400, 'too many entries'); }
    else $store[$col][$id] = clean_entry($col, $in['data'] ?? []);
    ftruncate($fp, 0); rewind($fp);
    fwrite($fp, json_encode($store, JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES));
    fflush($fp);
}
flock($fp, LOCK_UN); fclose($fp);
// Objects, not arrays, even when empty, so the page can always use Object.entries().
echo json_encode(['shortlist' => (object)$store['shortlist'], 'lists' => (object)$store['lists']], JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES);

<?php
// Today's sites (data/data.json, uploaded by the daily run) for signed-in users only, compressed when the browser allows.
require __DIR__ . '/common.php';
require_user();
session_write_close();
// ?city=chc -> Christchurch (data-chc.json); anything else -> Auckland (data.json).
$chc = ($_GET['city'] ?? '') === 'chc';
// ?part=NN -> one bucket of full site records (parts/NN.json); without it, the light summary of every site.
$part = $_GET['part'] ?? null;
if ($part !== null) {
    if (!preg_match('/^\d{2}$/', $part)) fail(400, 'Bad part');
    $f = DATA_DIR . ($chc ? '/parts-chc/' : '/parts/') . $part . '.json';
    if (!is_file($f)) fail(404, 'No details for this part yet');
} else {
    $f = DATA_DIR . ($chc ? '/data-chc.json' : '/data.json');
    if (!is_file($f)) fail(404, $chc ? 'Christchurch data is not ready yet: it appears after the next daily run' : 'No data yet: the daily run has not uploaded it');
}
header('Content-Type: application/json; charset=utf-8');
header('Last-Modified: ' . gmdate('D, d M Y H:i:s', filemtime($f)) . ' GMT');
if (extension_loaded('zlib') && strpos($_SERVER['HTTP_ACCEPT_ENCODING'] ?? '', 'gzip') !== false && !ini_get('zlib.output_compression')) ob_start('ob_gzhandler');
readfile($f);

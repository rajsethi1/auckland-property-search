<?php
// Today's sites (data/data.json, uploaded by the daily run) for signed-in users only, compressed when the browser allows.
require __DIR__ . '/common.php';
require_user();
session_write_close();
$f = DATA_DIR . '/data.json';
if (!is_file($f)) fail(404, 'No data yet: the daily run has not uploaded it');
header('Content-Type: application/json; charset=utf-8');
header('Last-Modified: ' . gmdate('D, d M Y H:i:s', filemtime($f)) . ' GMT');
if (extension_loaded('zlib') && strpos($_SERVER['HTTP_ACCEPT_ENCODING'] ?? '', 'gzip') !== false && !ini_get('zlib.output_compression')) ob_start('ob_gzhandler');
readfile($f);

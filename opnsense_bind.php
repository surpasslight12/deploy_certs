<?php
// OPNsense WebGUI 证书绑定: 更新 /conf/config.xml 中 system/webgui/ssl-certref 并重载 WebGUI
// 由 deploy_to_opnsense.sh 上传到远端执行: php opnsense_bind.php <refid>
if ($argc < 2) { echo "Usage: php opnsense_bind.php <refid>\n"; exit(2); }
$refid = $argv[1];

$conf = '/conf/config.xml';
if (!file_exists($conf) || !is_writable($conf)) {
    echo "Error: /conf/config.xml not writable or missing\n";
    exit(5);
}

libxml_use_internal_errors(true);
$dom = new DOMDocument('1.0', 'UTF-8');
$dom->preserveWhiteSpace = false;
$dom->formatOutput = true;

if ($dom->loadXML(file_get_contents($conf)) === false) {
    echo "Error: Failed to parse /conf/config.xml\n";
    exit(4);
}

$systems = $dom->getElementsByTagName('system');
if ($systems->length === 0) {
    echo "Error: Missing <system> node in /conf/config.xml\n";
    exit(3);
}

$system = $systems->item(0);
$webgui = null;
foreach ($system->childNodes as $child) {
    if ($child->nodeType === XML_ELEMENT_NODE && $child->nodeName === 'webgui') {
        $webgui = $child;
        break;
    }
}
if ($webgui === null) {
    $webgui = $dom->createElement('webgui');
    $system->appendChild($webgui);
}

$sslref = null;
foreach ($webgui->childNodes as $child) {
    if ($child->nodeType === XML_ELEMENT_NODE && $child->nodeName === 'ssl-certref') {
        $sslref = $child;
        break;
    }
}
if ($sslref === null) {
    $sslref = $dom->createElement('ssl-certref');
    $webgui->appendChild($sslref);
}

while ($sslref->hasChildNodes()) { $sslref->removeChild($sslref->firstChild); }
$sslref->appendChild($dom->createTextNode($refid));

if ($dom->save($conf) === false) {
    echo "Error: Failed to write updated config.xml\n";
    exit(3);
}

echo "Successfully updated WebGUI ssl-certref in /conf/config.xml\n";

$rout = [];
@exec('/usr/local/sbin/configctl webgui restart 2>&1', $rout, $rrc);
if (!empty($rout)) {
    echo implode("\n", $rout) . "\n";
}
if ($rrc !== 0) {
    echo "ERROR: configctl webgui restart failed (rc={$rrc})\n";
    exit(6);
}
echo "SUCCESS: WebGUI certificate binding updated and reloaded.\n";
exit(0);

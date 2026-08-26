/**
 * Equivalente webOS de:
 *   lib/core/utils/formatters.dart  (formatTime, formatSize, prettyTitle)
 *   lib/core/net/lan_guard.dart     (isPrivateIp)
 *
 * Funciones puras sin dependencias, compartidas por todos los módulos JS.
 * Si cambias la lógica de alguna, revisa su equivalente Dart.
 */
var FluxUtils = (function () {
  'use strict';

  function formatTime(seconds) {
    if (!seconds || !isFinite(seconds)) { return '--:--'; }
    var total = Math.floor(seconds);
    var hours = Math.floor(total / 3600);
    var minutes = Math.floor((total % 3600) / 60);
    var secs = total % 60;
    var mm = (minutes < 10 ? '0' : '') + minutes;
    var ss = (secs < 10 ? '0' : '') + secs;
    return hours > 0 ? hours + ':' + mm + ':' + ss : mm + ':' + ss;
  }

  function formatSize(bytes) {
    var units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var size = bytes;
    var unit = 0;
    while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit++; }
    return (unit === 0 ? size : size.toFixed(1)) + ' ' + units[unit];
  }

  function escape(text) {
    return String(text === null || text === undefined ? '' : text)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function prettyTitle(fileName) {
    var name = String(fileName);
    var dot = name.lastIndexOf('.');
    if (dot > 0 && name.length - dot <= 5) { name = name.substring(0, dot); }
    return name.replace(/[._]+/g, ' ').replace(/\s+/g, ' ').replace(/^\s+|\s+$/g, '');
  }

  function isPrivateIp(ip) {
    var parts = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(ip || '');
    if (!parts) { return false; }
    var a = +parts[1], b = +parts[2], c = +parts[3], d = +parts[4];
    if (a > 255 || b > 255 || c > 255 || d > 255) { return false; }
    if (a === 169 && b === 254) { return false; }
    if (a === 10) { return true; }
    if (a === 172 && b >= 16 && b <= 31) { return true; }
    if (a === 192 && b === 168) { return true; }
    return false;
  }

  function prefixOf(ip) {
    var parts = ip.split('.');
    return parts[0] + '.' + parts[1] + '.' + parts[2];
  }

  return {
    formatTime: formatTime,
    formatSize: formatSize,
    escape: escape,
    prettyTitle: prettyTitle,
    isPrivateIp: isPrivateIp,
    prefixOf: prefixOf
  };
}());

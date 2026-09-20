'use strict';
'require baseclass';
'require dom';
'require fs';
'require uci';
'require ui';

var CTL = '/usr/lib/isongwrt/ctl';

/* 调用后端脚本（/usr/lib/isongwrt/ctl），返回解析后的 JSON */
function call(args) {
	return fs.exec(CTL, args || []).then(function (res) {
		var out = ((res && res.stdout) || '').trim();
		var err = ((res && res.stderr) || '').trim();

		function tryParse(s) {
			try { return JSON.parse(s); } catch (e) { return null; }
		}

		var parsed = tryParse(out) || tryParse(err);
		if (parsed)
			return parsed;

		return { ok: false, error: out || err || '空输出' };
	}).catch(function (e) {
		return { ok: false, error: (e && e.message) || String(e) };
	});
}

function loadUci() {
	return uci.load('isongwrt');
}

function get(opt, def) {
	var v = uci.get('isongwrt', 'main', opt);
	return (v === null || v === undefined || v === '') ? def : v;
}

/* ---- 提醒：统一为弹窗（不再向页面顶部插入 alert-message，避免挤动布局） ---- */

function notice(title, body, opts) {
	var body_nodes = Array.isArray(body) ? body : [ body ];
	var timer = null;
	var btn = E('button', { 'class': 'btn cbi-button', 'click': close }, '关闭');

	/* Closing our own dialog must not hide whatever modal is on screen by then:
	   an auto-close timer may fire after another modal replaced this notice. */
	function close() {
		if (timer) { clearTimeout(timer); timer = null; }
		if (dlg && dlg.contains(btn))
			ui.hideModal();
	}

	var dlg = ui.showModal(title, body_nodes.concat([
		E('div', { 'class': 'right', 'style': 'margin-top:.75rem' }, [ btn ])
	]));

	if (opts && opts.autoClose)
		timer = setTimeout(close, opts.autoClose);
}

function alert(msg, level, title) {
	var icon = (level === 'error') ? '❌ ' : (level === 'warning' ? '⚠️ ' : '✅ ');
	var t = title || (level === 'error' ? '操作失败' : (level === 'warning' ? '提示' : '操作完成'));
	notice(t, E('p', { 'style': 'margin:.25rem 0' }, icon + msg),
		(level === 'error' || level === 'warning') ? null : { autoClose: 1800 });
	return Promise.resolve();
}

function notify(res, okMsg) {
	if (res && res.ok) {
		notice('操作完成', E('p', { 'style': 'margin:.25rem 0' }, '✅ ' + (okMsg || '操作成功')), { autoClose: 1800 });
	} else {
		var err = ((res && res.error) || '未知错误');
		notice('操作失败', [
			E('p', { 'style': 'margin:.25rem 0' }, '❌ ' + err.split('\n')[0]),
			err.split('\n').length > 1
				? E('pre', { 'style': 'max-height:30vh;overflow:auto;white-space:pre-wrap;font-size:12px;background:#111;color:#ddd;padding:8px;border-radius:4px' }, err)
				: ''
		]);
	}
	return res;
}

/* ---- 保存：自己走一遍「保存 + 应用」，避免 LuCI 往页面顶部插提醒 ---- */
function saveMaps(silent) {
	var tasks = [];
	var root = document.getElementById('maincontent') || document.getElementById('view') || document.body;
	root.querySelectorAll('.cbi-map').forEach(function (node) {
		var map = dom.findClassInstance(node);
		if (map && typeof map.save === 'function')
			tasks.push(map.save(null, true));      // silent=true：不弹顶部通知
	});
	return Promise.all(tasks);
}

function handleSave(ev) {
	return saveMaps(true).catch(function (e) {
		alert(String((e && e.message) || e), 'error', '保存失败');
		throw e;
	});
}

function handleSaveApply(ev, mode) {
	/* Save silently (silent=true, no duplicate top-of-page notification) and hand
	   the apply over to LuCI: `mode == '0'` means "Save & Apply", which must stay a
	   checked apply (connectivity confirmation + automatic rollback on timeout).
	   LuCI's own apply flow already reports progress and the result, so no extra
	   success modal is raised here — it would appear before the apply actually
	   succeeded and could contradict a cancelled confirmation dialog. */
	return saveMaps(true).then(function () {
		return ui.changes.apply(mode == '0');
	}).catch(function (e) {
		alert(String((e && e.message) || e), 'error', '保存失败');
		throw e;
	});
}

function busy(promise, msg) {
	ui.showModal('请稍候', [ E('p', { 'class': 'spinning' }, msg || '处理中…') ]);
	return promise.then(function (r) {
		ui.hideModal();
		return r;
	}).catch(function (e) {
		ui.hideModal();
		throw e;
	});
}

/* LuCI 模块必须返回 class（loader 会 new 它），故用 baseclass.extend */
return baseclass.extend({
	call: call,
	alert: alert,
	notice: notice,
	handleSave: handleSave,
	handleSaveApply: handleSaveApply,
	loadUci: loadUci,
	get: get,
	notify: notify,
	busy: busy
});

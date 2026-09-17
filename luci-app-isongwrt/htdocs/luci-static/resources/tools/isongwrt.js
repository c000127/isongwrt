'use strict';
'require baseclass';
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

function set(opt, val) {
	uci.set('isongwrt', 'main', opt, val);
}

function applyUci() {
	return uci.save().then(function () { return uci.apply(); });
}

function notify(res, okMsg) {
	if (res && res.ok)
		ui.addNotification(null, E('p', {}, okMsg || '操作成功'), 'info');
	else
		ui.addNotification(null, E('p', {}, '失败：' + ((res && res.error) || '未知错误')), 'error');
	return res;
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
	loadUci: loadUci,
	get: get,
	set: set,
	applyUci: applyUci,
	notify: notify,
	busy: busy
});

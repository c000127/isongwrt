'use strict';
'require fs';
'require uci';

var CTL = '/usr/lib/isongwrt/ctl';

function call(args) {
	return fs.exec(CTL, args || []).then(function (res) {
		var out = ((res && res.stdout) || '').trim();
		try {
			return JSON.parse(out);
		} catch (e) {
			return {
				ok: false,
				error: out || ((res && res.stderr) || '').trim() || '空输出'
			};
		}
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
	return uci.save().then(function () {
		return uci.apply();
	});
}

function notify(res, okMsg) {
	if (res && res.ok)
		ui.addNotification(null, E('p', {}, okMsg || '操作成功'), 'info');
	else
		ui.addNotification(null, E('p', {}, '失败：' + ((res && res.error) || '未知错误')), 'error');
	return res;
}

function busy(promise, msg) {
	var node = E('p', { 'class': 'spinning' }, msg || '处理中…');
	ui.showModal('请稍候', [node]);
	return promise.then(function (r) {
		ui.hideModal();
		return r;
	}).catch(function (e) {
		ui.hideModal();
		throw e;
	});
}

return {
	call: call,
	loadUci: loadUci,
	get: get,
	set: set,
	applyUci: applyUci,
	notify: notify,
	busy: busy
};

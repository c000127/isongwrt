'use strict';
'require view';
'require ui';
'require poll';
'require tools.isongwrt as iso';

function btn(label, style, fn) {
	return E('button', { 'class': 'btn cbi-button cbi-button-' + style, 'click': fn }, label);
}

return view.extend({
	load: function () {
		return iso.call(['log', '300']);
	},

	render: function (data) {
		var self = this;
		self.log = (data && data.log) || '';
		self.auto = true;

		self.pre = E('pre', {
			'style': 'max-height:60vh;overflow:auto;white-space:pre-wrap;word-break:break-all;' +
				'font-size:12px;background:#111;color:#ddd;padding:8px;border-radius:4px'
		}, self.log || '（暂无日志）');

		self.root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, '日志'),
			E('div', { 'class': 'cbi-section' }, [
				/* 与 form.Flag 完全一致的原生复选框结构：div.cbi-checkbox > input + label[for] */
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'iso-autorefresh' }, '自动刷新'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('div', { 'class': 'cbi-checkbox' }, [
							E('input', {
								'id': 'iso-autorefresh', 'type': 'checkbox',
								'checked': self.auto ? '' : null,
								'change': function (ev) { self.auto = ev.target.checked; }
							}),
							E('label', { 'for': 'iso-autorefresh' })
						]),
						E('div', { 'class': 'cbi-value-description' }, '每 5 秒刷新一次（最近 300 行）')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '操作'),
					E('div', { 'class': 'cbi-value-field' }, [
						btn('刷新', 'action', function () { return self.refresh(); }),
						' ',
						btn('重启服务', 'apply', function () {
							return iso.busy(iso.call(['service', 'restart']), '重启服务…').then(function (r) {
								iso.notify(r, '服务已重启');
								return self.refresh();
							});
						})
					])
				])
			]),
			self.pre
		]);

		poll.add(function () {
			if (!self.auto)
				return Promise.resolve();
			return iso.call(['log', '300']).then(function (r) {
				if (r && r.ok && r.log !== self.log) {
					self.log = r.log || '';
					self.pre.textContent = self.log || '（暂无日志）';
				}
			});
		}, 5);

		return self.root;
	},

	refresh: function () {
		var self = this;
		return iso.call(['log', '300']).then(function (r) {
			self.log = (r && r.log) || '';
			self.pre.textContent = self.log || '（暂无日志）';
		});
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

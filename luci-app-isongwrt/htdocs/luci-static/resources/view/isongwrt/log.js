'use strict';
'require view';
'require dom';
'require ui';
'require poll';
'require tools.isongwrt as iso';

return view.extend({
	load: function () {
		return iso.call(['log', '300']);
	},

	render: function (data) {
		var self = this;
		this.log = (data && data.log) || '';
		this.auto = true;

		this.pre = E('pre', {
			'style': 'max-height:60vh;overflow:auto;white-space:pre-wrap;word-break:break-all;' +
				'font-size:12px;background:#111;color:#ddd;padding:8px;border-radius:4px'
		}, this.log || '（暂无日志）');

		this.root = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, '日志'),
			E('div', { 'class': 'cbi-map-descr' },
				'来源：syslog（logread，含内核 stdout/stderr）。日志级别在配置文件的 log.level 中设置。'),

			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title', 'for': 'iso-autorefresh' }, '自动刷新'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('label', { 'class': 'cbi-checkbox' }, [
							E('input', {
								'id': 'iso-autorefresh', 'type': 'checkbox', 'class': 'cbi-input-checkbox',
								'checked': this.auto ? '' : null,
								'change': function (ev) { self.auto = ev.target.checked; }
							}),
							' ',
							E('span', {}, '每 5 秒刷新一次（最近 300 行）')
						])
					])
				])
			]),

			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function () { return this.refresh(); })
				}, '刷新'),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function () {
						var that = this;
						return iso.busy(iso.call(['service', 'restart']), '重启服务…').then(function (r) {
							iso.notify(r, '服务已重启');
							return that.refresh();
						});
					})
				}, '重启服务')
			]),

			this.pre
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

		return this.root;
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

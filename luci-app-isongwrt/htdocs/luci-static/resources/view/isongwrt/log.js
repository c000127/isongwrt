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
		this.log = (data && data.log) || '';
		this.auto = true;
		this.root = E('div', { 'class': 'cbi-map' });
		this.paint();
		var self = this;
		poll.add(function () {
			if (!self.auto) return Promise.resolve();
			return iso.call(['log', '300']).then(function (r) {
				if (r && r.ok && r.log !== self.log) {
					self.log = r.log || '';
					if (self.pre) self.pre.textContent = self.log || '（暂无日志）';
				}
			});
		}, 5);
		return this.root;
	},

	refresh: function () {
		var self = this;
		return iso.call(['log', '300']).then(function (r) {
			self.log = (r && r.log) || '';
			self.paint();
		});
	},

	paint: function () {
		var self = this;
		this.pre = E('pre', {
			'style': 'max-height:60vh;overflow:auto;white-space:pre-wrap;word-break:break-all;font-size:12px;background:#111;color:#ddd;padding:8px;border-radius:4px'
		}, this.log || '（暂无日志）');
		dom.content(this.root, [
			E('h2', {}, '日志'),
			E('div', { 'class': 'cbi-map-descr' }, '来源：syslog（logread，含内核 stdout/stderr）。日志级别在配置文件的 log.level 中设置。'),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function () { return this.refresh(); })
				}, '刷新'),
				E('label', { 'class': 'cbi-checkbox', 'style': 'margin-left:1em' }, [
					E('input', {
						'type': 'checkbox', 'checked': this.auto ? '' : null,
						'change': ui.createHandlerFn(this, function (ev) { this.auto = ev.target.checked; })
					}), ' 自动刷新（5s）'
				]),
				E('button', {
					'class': 'btn cbi-button cbi-button-apply', 'style': 'margin-left:1em',
					'click': ui.createHandlerFn(this, function () {
						return iso.busy(iso.call(['service', 'restart']), '重启服务…').then(function (r) {
							iso.notify(r, '服务已重启');
							return self.refresh();
						});
					})
				}, '重启服务')
			]),
			this.pre
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

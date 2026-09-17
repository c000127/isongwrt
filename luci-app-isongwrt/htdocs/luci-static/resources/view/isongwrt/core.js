'use strict';
'require view';
'require dom';
'require ui';
'require tools.isongwrt as iso';

return view.extend({
	load: function () {
		return Promise.all([ iso.loadUci(), iso.call(['status']), iso.call(['channels']), iso.call(['installed']) ]);
	},

	render: function (data) {
		this.status = data[1] || {};
		this.channels = (data[2] && data[2].channels) || [];
		this.installed = data[3] || {};
		this.channel = iso.get('channel', 'stable');
		this.pin = '';
		this.root = E('div', { 'class': 'cbi-map' });
		this.paint();
		return this.root;
	},

	reload: function () {
		var self = this;
		return Promise.all([ iso.call(['channels']), iso.call(['installed']), iso.call(['status']) ])
			.then(function (r) {
				self.channels = (r[0] && r[0].channels) || [];
				self.installed = r[1] || {};
				self.status = r[2] || {};
				self.paint();
			});
	},

	install: function () {
		var self = this, ch = this.channel, pin = (this.pin || '').trim();
		var label = pin ? ('安装 ' + pin) : ('安装 ' + ch + ' 渠道最新版');
		var pre = E('pre', {
			'style': 'max-height:40vh;overflow:auto;white-space:pre-wrap;font-size:12px;background:#111;color:#ddd;padding:8px'
		}, '正在启动安装任务…');
		var closeBtn = E('button', { 'class': 'btn', 'click': function () { ui.hideModal(); } }, '关闭');
		ui.showModal(label, [ pre, E('div', { 'class': 'right' }, closeBtn) ]);
		var timer = null;
		function stop() { if (timer) { clearInterval(timer); timer = null; } }
		function poll() {
			return iso.call(['install-status']).then(function (r) {
				pre.textContent = (r && r.log) || '(无输出)';
				pre.scrollTop = pre.scrollHeight;
				if (!r || r.state === 'done') {
					stop();
					iso.notify({ ok: true }, label + ' 完成');
					return self.reload();
				}
				if (r.state === 'failed') {
					stop();
					iso.notify({ ok: false, error: '安装失败，详见日志' }, '');
					return self.reload();
				}
			});
		}
		return iso.call(pin ? ['install-bg', ch, pin] : ['install-bg', ch]).then(function (r) {
			if (!r || !r.ok) { stop(); ui.hideModal(); iso.notify(r, ''); return; }
			timer = setInterval(poll, 3000);
			return poll();
		});
	},

	paint: function () {
		var self = this, st = this.status || {}, inst = this.installed || {};
		var chOpts = this.channels.map(function (c) {
			return E('option', { 'value': c.name, 'selected': c.name === self.channel ? '' : null },
				c.name + '（最新 ' + (c.latest || '-') + '）');
		});
		var instRows = (inst.versions || []).map(function (v) {
			var isActive = v.version === inst.active;
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, v.version + (isActive ? ' ★' : '')),
				E('td', { 'class': 'td left' }, (v.size ? (Math.round(v.size / 1048576 * 10) / 10) + ' MiB' : '-')),
				E('td', { 'class': 'td left' }, (v.sha256 || '').substr(0, 16)),
				E('td', { 'class': 'td left' }, [
					isActive ? E('em', {}, '当前激活') : E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(self, function () {
							return iso.busy(iso.call(['activate', v.version]), '切换内核…').then(function (r) {
								iso.notify(r, '已切换到 ' + v.version);
								return self.reload();
							});
						})
					}, '激活'),
					' ',
					isActive ? '' : E('button', {
						'class': 'btn cbi-button cbi-button-remove',
						'click': ui.createHandlerFn(self, function () {
							return iso.busy(iso.call(['remove', v.version]), '删除…').then(function (r) {
								iso.notify(r, '已删除 ' + v.version);
								return self.reload();
							});
						})
					}, '删除')
				])
			]);
		});
		if (!instRows.length)
			instRows = [ E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 4 }, '尚未安装任何内核') ]) ];

		dom.content(this.root, [
			E('h2', {}, '内核管理'),
			E('div', { 'class': 'cbi-map-descr' },
				'从官方仓库 SagerNet/sing-box Releases 下载安装，支持 stable / rc / beta / alpha 四级渠道，自动匹配本机架构（优先 musl 构建）。'),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '安装 / 升级'),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '渠道'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', {
							'class': 'cbi-input-select',
							'change': ui.createHandlerFn(this, function (ev) { this.channel = ev.target.value; iso.set('channel', ev.target.value); })
						}, chOpts),
						E('div', { 'class': 'cbi-value-description' },
							'当前内核：' + (st.version || '未安装') + '；网络受限时可在下方填写 GitHub 加速前缀。')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '指定版本（可选）'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'v1.15.0-alpha.5',
							'input': ui.createHandlerFn(this, function (ev) { this.pin = ev.target.value; })
						}),
						E('div', { 'class': 'cbi-value-description' }, '留空 = 安装所选渠道的最新版')
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, 'GitHub 加速前缀'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'type': 'text', 'class': 'cbi-input-text', 'placeholder': 'https://ghfast.top/',
							'value': iso.get('github_proxy', ''),
							'change': ui.createHandlerFn(this, function (ev) { iso.set('github_proxy', ev.target.value); return iso.applyUci(); })
						})
					])
				]),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, function () { return this.install(); })
					}, '开始安装 / 升级'),
					E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, function () {
							return iso.busy(iso.call(['rollback']), '回滚内核…').then(function (r) {
								iso.notify(r, '已回滚');
								return self.reload();
							}.bind(self));
						})
					}, '回滚到上一版本')
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '已安装版本'),
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, '版本'),
						E('th', { 'class': 'th' }, '大小'),
						E('th', { 'class': 'th' }, 'SHA256'),
						E('th', { 'class': 'th' }, '操作')
					])
				].concat(instRows))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

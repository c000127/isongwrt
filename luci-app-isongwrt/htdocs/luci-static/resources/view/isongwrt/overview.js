'use strict';
'require view';
'require dom';
'require ui';
'require tools.isongwrt as iso';

function row(k, v) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '33%' }, E('strong', {}, k)),
		E('td', { 'class': 'td left' }, v)
	]);
}

return view.extend({
	load: function () {
		return Promise.all([ iso.loadUci(), iso.call(['status']) ]);
	},

	render: function (data) {
		this.status = data[1] || {};
		this.uciLoaded = true;
		this.root = E('div', { 'class': 'cbi-map' });
		this.paint();
		return this.root;
	},

	refresh: function () {
		var self = this;
		return iso.call(['status']).then(function (st) {
			self.status = st || {};
			self.paint();
		});
	},

	action: function (args, label) {
		var self = this;
		return iso.busy(iso.call(args), label + '…').then(function (r) {
			iso.notify(r, label + ' 完成');
			return self.refresh();
		});
	},

	toggleEnable: function (on) {
		var self = this;
		iso.set('enabled', on ? '1' : '0');
		return iso.applyUci().then(function () {
			return self.action(['service', on ? 'enable' : 'disable'],
				on ? '启用开机自启' : '关闭开机自启');
		});
	},

	paint: function () {
		var self = this, st = this.status || {};
		var running = st.running === true;
		var body = [
			E('h2', {}, 'isongwrt 运行状态'),
			E('div', { 'class': 'cbi-map-descr' }, 'sing-box 内核管理与配置面板'),
			E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, [
					row('运行状态', running
						? E('span', { 'style': 'color:green' }, '运行中 (PID ' + (st.pid || '?') + ')')
						: E('span', { 'style': 'color:red' }, '已停止')),
					row('开机自启', st.enabled ? '已启用' : '未启用'),
					row('内核版本', st.version || E('em', {}, '未安装内核（请到「内核管理」安装）')),
					row('激活版本', st.active || '-'),
					row('渠道 / 架构', (st.channel || '-') + ' / ' + (st.arch || '-')),
					row('内核路径', st.core_path || '-'),
					row('配置目录', (st.conf_dir || '-') + '（' + (st.conf_files || 0) + ' 个分片文件）'),
					row('配置校验', st.config_check === 'ok'
						? E('span', { 'style': 'color:green' }, '通过')
						: E('span', { 'style': 'color:red' }, '未通过（查看日志页）')),
					row('API / 面板', (st.api || '-') + (st.dashboard ? '（官方 dashboard 已启用）' : ''))
				])
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(this, function () {
						return this.action(['service', running ? 'stop' : 'start'], running ? '停止服务' : '启动服务');
					})
				}, running ? '停止' : '启动'),
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function () {
						return this.action(['service', 'restart'], '重启服务');
					})
				}, '重启'),
				E('button', {
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, function () { return this.refresh(); })
				}, '刷新')
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('label', { 'class': 'cbi-checkbox' }, [
					E('input', {
						'type': 'checkbox',
						'checked': st.enabled ? '' : null,
						'change': ui.createHandlerFn(this, function (ev) {
							return this.toggleEnable(ev.target.checked);
						})
					}),
					' 开机自启（procd init）'
				])
			])
		];
		dom.content(this.root, body);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

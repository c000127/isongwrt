'use strict';
'require view';
'require fs';
'require dom';
'require ui';
'require tools.isongwrt as iso';

var UPLOAD_TMP = '/tmp/isongwrt-upload.json';

return view.extend({
	load: function () {
		return Promise.all([ iso.call(['config-list']), iso.call(['status']) ]);
	},

	render: function (data) {
		this.list = data[0] || {};
		this.status = data[1] || {};
		this.files = (this.list.files || []);
		this.backups = (this.list.backups || []);
		this.current = this.files.length ? this.files[0].name : '10-user';
		this.content = '';
		this.root = E('div', { 'class': 'cbi-map' });
		var self = this;
		return this.loadContent(this.current).then(function () {
			self.paint();
			return self.root;
		});
	},

	loadContent: function (name) {
		var self = this;
		return iso.call(['config-get', name]).then(function (r) {
			self.content = r && r.ok ? (r.content || '') : '';
			if (r && !r.ok) iso.notify(r, '读取配置失败');
		});
	},

	paint: function () {
		var self = this;
		var fileOpts = this.files.map(function (f) {
			return E('option', { 'value': f.name, 'selected': f.name === self.current ? '' : null },
				f.name + '.json（' + f.size + ' B）');
		});
		var backupRows = this.backups.slice(0, 20).map(function (b) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, b),
				E('td', { 'class': 'td left' }, E('button', {
					'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(self, function () {
						return iso.busy(iso.call(['config-restore', b]), '恢复备份…').then(function (r) {
							iso.notify(r, '已恢复 ' + b);
							return self.loadContent(self.current).then(function () { self.paint(); });
						});
					})
				}, '恢复'))
			]);
		});

		dom.content(this.root, [
			E('h2', {}, '配置管理'),
			E('div', { 'class': 'cbi-map-descr' },
				'配置以「分片目录」方式加载：分片文件放入 conf 目录后由 sing-box 合并（-C 目录模式）。面板自动维护 90-isongwrt-api.json（API/面板分片），升级不会覆盖你的配置；保存前会自动 sing-box check 校验，未通过自动回退。'),
			E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, '分片文件'),
					E('div', { 'class': 'cbi-value-field' }, [
						E('select', {
							'class': 'cbi-input-select',
							'change': ui.createHandlerFn(this, function (ev) {
								this.current = ev.target.value;
								return this.loadContent(this.current).then(function () { self.paint(); });
							})
						}, fileOpts.concat([ E('option', { 'value': '__new__' }, '＋ 新建 10-user.json') ]))
					])
				]),
				E('textarea', {
					'class': 'cbi-input-textarea', 'style': 'width:100%;height:340px;font-family:monospace',
					'spellcheck': 'false',
					'input': ui.createHandlerFn(this, function (ev) { this.content = ev.target.value; })
				}, this.content),
				E('div', { 'class': 'cbi-page-actions' }, [
					E('button', {
						'class': 'btn cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, function () { return this.save(); })
					}, '校验并保存'),
					E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, function () {
							return iso.busy(iso.call(['check']), '校验配置…').then(function (r) {
								iso.notify(r, '配置校验通过');
							});
						})
					}, '仅校验'),
					E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, function () {
							return iso.busy(iso.call(['service', 'restart']), '重启服务…').then(function (r) {
								iso.notify(r, '服务已重启');
							});
						})
					}, '重启服务'),
					E('button', {
						'class': 'btn cbi-button',
						'click': ui.createHandlerFn(this, function () {
							return iso.busy(iso.call(['config-backup']), '创建快照…').then(function (r) {
								iso.notify(r, '快照已创建');
								return iso.call(['config-list']).then(function (l) {
									self.backups = (l && l.backups) || [];
									self.paint();
								});
							});
						})
					}, '创建快照'),
					E('input', {
						'type': 'file', 'accept': '.json', 'style': 'display:inline-block;margin-left:1em',
						'change': ui.createHandlerFn(this, function (ev) { return this.upload(ev); })
					})
				])
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '备份（最近 20 条）'),
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class': 'th' }, '备份文件'), E('th', { 'class': 'th' }, '操作')
					])
				].concat(backupRows.length ? backupRows
					: [ E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 2 }, '暂无备份') ]) ]))
			])
		]);
	},

	save: function () {
		var self = this, name = this.current === '__new__' ? '10-user' : this.current;
		return fs.write(UPLOAD_TMP, this.content).then(function () {
			return iso.busy(iso.call(['config-save', name]), '校验并保存…');
		}).then(function (r) {
			iso.notify(r, '已保存 ' + name + '.json');
			self.current = name;
			return iso.call(['config-list']).then(function (l) {
				self.list = l || {};
				self.files = (l && l.files) || [];
				self.backups = (l && l.backups) || [];
				self.paint();
			});
		});
	},

	upload: function (ev) {
		var self = this, file = ev.target.files && ev.target.files[0];
		if (!file) return Promise.resolve();
		return new Promise(function (resolve, reject) {
			var reader = new FileReader();
			reader.onload = function () {
				self.content = String(reader.result);
				self.current = '10-user';
				resolve();
			};
			reader.onerror = reject;
			reader.readAsText(file);
		}).then(function () { return self.save(); });
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});

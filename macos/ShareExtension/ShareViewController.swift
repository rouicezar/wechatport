import AppKit
import UniformTypeIdentifiers
import os

@objc(ShareViewController)
final class ShareViewController: NSViewController {
    private let worker = DispatchQueue(label: "com.rouice.wechatport.receive")
    private let log = Logger(subsystem: "com.rouice.wechatport.share", category: "receiving")
    private var providers: [NSItemProvider] = []
    private var store: InboxStore?
    private var control = ReceiveControl()
    private var finished = false
    private var started = false
    private var container: URL?
    private let nameField = NSTextField(string: "")
    private let typePicker = NSPopUpButton(frame:.zero,pullsDown:false)
    private let progress = NSProgressIndicator()
    private var choices: [ShareChoice] = []
    private var collection: ShareCollection?
    private var collectionLoadFailed = false
    private let batchLabel = NSTextField(labelWithString:"第 1 批 · 本次收集共 1 批")
    private let next = NSButton(title:"添加下一批次",target:nil,action:nil)
    private let label = NSTextField(wrappingLabelWithString: "正在保存附件，请保留原文件。")
    private let retry = NSButton(title: "重试接收", target: nil, action: nil)
    private let done = NSButton(title: "完成", target: nil, action: nil)
    private let cancel = NSButton(title: "取消分享", target: nil, action: nil)
    override func loadView() {
        let root = NSView(frame:NSRect(x:0,y:0,width:480,height:360))
        let icon = NSImageView(frame:NSRect(x:28,y:294,width:38,height:38))
        icon.image = NSImage(systemSymbolName:"tray.and.arrow.down.fill",accessibilityDescription:"收集聊天记录")
        icon.contentTintColor = NSColor.systemGreen; root.addSubview(icon)
        let title = NSTextField(labelWithString:"收集到 WeChatPort")
        next.toolTip = "暂存本批并返回，请自行选择下一批，再手动分享。最后点击完成统一加入收集箱。"
        title.font = .systemFont(ofSize:20,weight:.semibold); title.frame = NSRect(x:80,y:306,width:360,height:27); root.addSubview(title)
        label.font = .systemFont(ofSize:12); label.textColor = .secondaryLabelColor
        label.frame = NSRect(x:80,y:278,width:365,height:25); root.addSubview(label)
        let nameLabel = NSTextField(labelWithString:"群或联系人名称")
        nameLabel.font = .systemFont(ofSize:13,weight:.medium); nameLabel.frame = NSRect(x:28,y:235,width:420,height:22); root.addSubview(nameLabel)
        nameField.placeholderString = "例如：产品讨论群"; nameField.frame = NSRect(x:28,y:196,width:424,height:32)
        nameField.font = .systemFont(ofSize:15); nameField.bezelStyle = .roundedBezel
        nameField.setAccessibilityLabel("群或联系人名称"); root.addSubview(nameField)
        let typeLabel = NSTextField(labelWithString:"简报类型")
        typeLabel.font = .systemFont(ofSize:13,weight:.medium); typeLabel.frame = NSRect(x:28,y:155,width:420,height:22); root.addSubview(typeLabel)
        typePicker.frame = NSRect(x:24,y:116,width:432,height:32); typePicker.setAccessibilityLabel("简报类型"); root.addSubview(typePicker)
        progress.frame = NSRect(x:28,y:86,width:424,height:4); progress.style = .bar; progress.isIndeterminate = true; progress.startAnimation(nil); root.addSubview(progress)
        batchLabel.frame = NSRect(x:28,y:59,width:424,height:22); batchLabel.font = .systemFont(ofSize:12); batchLabel.textColor = .secondaryLabelColor; root.addSubview(batchLabel)
        next.frame = NSRect(x:24,y:23,width:160,height:32); next.target = self; next.action = #selector(addNextBatch); next.isEnabled = false; root.addSubview(next)
        retry.frame = NSRect(x:28,y:23,width:150,height:32); retry.target = self; retry.action = #selector(retryShare); retry.isHidden = true
        cancel.frame = NSRect(x:236,y:23,width:100,height:32); cancel.title = "取消"; cancel.target = self; cancel.action = #selector(cancelShare)
        done.frame = NSRect(x:344,y:23,width:108,height:32); done.bezelStyle = .rounded; done.bezelColor = .systemGreen; done.contentTintColor = .white
        done.target = self; done.action = #selector(completeShare); done.keyEquivalent = "\r"; done.isEnabled = false
        root.addSubview(retry); root.addSubview(cancel); root.addSubview(done); view = root
        if let group = Bundle(for:Self.self).object(forInfoDictionaryKey:"WeChatPortAppGroup") as? String,
           let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:group) {
            container = url
            do {
                collection = try ShareCollection.active(container:url)
                if let collection {
                    nameField.stringValue = collection.name
                    batchLabel.stringValue = "第 \(collection.batchIDs.count+1) 批 · 本次收集共 \(collection.batchIDs.count+1) 批"
                }
            } catch { collectionLoadFailed = true }
            if let catalog = ShareCatalog.load(url) {
                choices = catalog.types
                if collection == nil, let expiry = catalog.expiresAt, expiry > Date() { nameField.stringValue = catalog.suggestedName }
                typePicker.addItems(withTitles:choices.map(\.name))
                if !nameField.stringValue.isEmpty, let index = choices.firstIndex(where:{$0.id == (collection?.templateID ?? catalog.suggestedType)}) { typePicker.selectItem(at:index) }
            }
        }
        if choices.isEmpty {
            choices = [ShareChoice(id:"focus",name:"对话重点"),ShareChoice(id:"personal",name:"与我相关"),ShareChoice(id:"actions",name:"资料与行动项")]
            typePicker.addItems(withTitles:choices.map(\.name))
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard !started else { return }; started = true
        providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        if collectionLoadFailed { label.stringValue = "暂存收集无法读取，请在主App检查后重试；本次附件尚未接收"; return }
        begin()
    }
    private func begin() {
        retry.isHidden = true; next.isHidden = false
        label.stringValue = "正在接收附件，可以先填写信息"
        worker.async { [self] in
            do {
                guard !providers.isEmpty,
                      let group = Bundle(for: Self.self).object(forInfoDictionaryKey: "WeChatPortAppGroup") as? String,
                      let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
                else { throw InboxError.invalidFile }
                let root = InboxStore.inbox(container: container)
                let recovered = try InboxStore.recover(root: root)
                log.info("event=recovery recovered=\(recovered.recovered) incomplete=\(recovered.incomplete) busy=\(recovered.busy)")
                if store == nil {
                    store = try InboxStore(root: root, expected: providers.count)
                    control.onCancel(store!.cancellationMarker())
                }
                receive(index: 0)
            } catch { failed() }
        }
    }
    // Each provider URL is copied before returning its callback, never queued for later use.
    private func receive(index: Int) {
        do {
            try control.check()
            guard let store else { throw InboxError.incomplete }
            if index == providers.count {
                try store.finish(control: control)
                InboxSignal.post()
                log.info("event=batch_ready attachments=\(self.providers.count)")
                DispatchQueue.main.async { [self] in
                    guard !finished else { return }; finished = true
                    label.stringValue = "已接收 \(providers.count) 个附件"
                    progress.stopAnimation(nil); progress.isIndeterminate = false; progress.doubleValue = 100
                    cancel.isHidden = false
                    retry.isHidden = true
                    done.isHidden = false; done.isEnabled = true; next.isEnabled = true
                    view.window?.makeFirstResponder(nameField.stringValue.isEmpty ? nameField : done)
                }
                return
            }
            if try store.hasCompleted(index) { receive(index: index + 1); return }
            let provider = providers[index]
            let fileURL = UTType.fileURL.identifier
            let identifier: String
            if provider.hasItemConformingToTypeIdentifier(fileURL) { identifier = fileURL }
            else if let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .zip) == true
            }) { identifier = type }
            else { throw InboxError.invalidFile }
            let name = provider.suggestedName
            let copied: (URL?, Error?) -> Void = { [self] url, error in
                do {
                    guard error == nil, let url else { throw InboxError.invalidFile }
                    let type = UTType(filenameExtension: url.pathExtension)
                    try store.copy(url, index: index, originalName: name,
                                   mediaType: type?.preferredMIMEType ?? "application/octet-stream", control: control)
                    log.info("event=attachment_copied index=\(index)")
                    worker.async { [self] in receive(index: index + 1) }
                } catch { worker.async { [self] in failed() } }
            }
            if identifier == fileURL {
                provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                    var url = item as? URL
                    if url == nil, let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    copied(url, error)
                }
            } else { provider.loadFileRepresentation(forTypeIdentifier: identifier, completionHandler: copied) }
        } catch { failed() }
    }
    private func failed() {
        log.error("event=receive_incomplete")
        DispatchQueue.main.async { [self] in
            guard !finished else { return }
            label.stringValue = "接收未完成，尚未报告成功。已复制的内容仍保留，可重试；若源文件已失效，请取消后重新分享。"
            retry.isHidden = false; next.isHidden = true
        }
    }
    @objc private func completeShare() { submit(complete:true) }
    @objc private func addNextBatch() { submit(complete:false) }
    private func submit(complete: Bool) {
        guard finished, let store, let container else { return }
        let name = ShareIntake.normalized(nameField.stringValue)
        guard !name.isEmpty, name.count <= 200 else {
            label.stringValue = "请填写群或联系人名称"; view.window?.makeFirstResponder(nameField); return
        }
        do {
            collection = try ShareCollection.update(id:collection?.id,batchID:store.id,name:name,templateID:choices[typePicker.indexOfSelectedItem].id,workspaceID:collection?.workspaceID ?? ShareCatalog.load(container)?.workspaceID,complete:complete,container:container)
            done.isEnabled = false; next.isEnabled = false
            if let catalog = ShareCatalog.load(container), ShareIntake.normalized(catalog.suggestedName) == name {
                try? ShareIntake.write(ShareCatalog(types:catalog.types,suggestedName:"",suggestedType:catalog.suggestedType,expiresAt:nil,workspaceID:catalog.workspaceID),to:ShareCatalog.url(container))
            }
            InboxSignal.post()
            extensionContext?.completeRequest(returningItems:[],completionHandler:nil)
        } catch {
            if let active = try? ShareCollection.active(container:container), active.batchIDs.contains(store.id) { collection = active }
            label.stringValue = "收集未提交，请重试；附件和暂存批次仍保留"
        }
    }
    @objc private func retryShare() { begin() }
    @objc private func cancelShare() {
        guard finished || control.cancel() else { return }
        finished = true
        worker.async { [self] in
            // Callback may still be copying; cancellation prevents publication, and
            // journal writes stay ordered after that callback (see receive callback).
            log.info("event=receive_cancelled")
        }
        extensionContext?.cancelRequest(withError: NSError(domain: "com.rouice.wechatport.share", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "接收已取消，未完成文件保留；请保留原文件并重新分享"]))
    }
}

import AppKit

extension SelfTest {
    /// Isolated web fixture: replaces post with an in-page capture before making any
    /// requests. No ReaderInteraction, terminal, live request file or provider is used.
    static func readerRequestKeyboard() {
        guard Paths.webRoot != nil else { check("request keyboard: web assets", false); return }
        let window = makeWindow()
        defer { window.orderOut(nil) }
        let page = WebPage(page: "reader.html?layout=main", identifier: "selftest.request-keyboard")
        page.webView.frame = NSRect(x: 0, y: 0, width: 760, height: 700)
        window.contentView?.addSubview(page.webView)
        guard waitUntil(10, { page.ready }) else { check("request keyboard: page ready", false); return }
        let script = #"""
        (() => {
          const originalPost = hantuuRender.post, results = {};
          const messages = [];
          hantuuRender.post = value => messages.push(value);
          const replies = () => messages.filter(m => m.type === 'readerRequest');
          const key = (id, key, fromComposer = false) => ReaderParity.requestKey({requestID:id,key,fromComposer});
          const setup = (id, questions = null) => {
            ReaderParity.setRequests([]); messages.length = 0;
            ReaderParity.setRequests([{id,tool:questions ? 'AskUserQuestion' : 'Bash',inputJSON:JSON.stringify(questions ? {questions} : {command:'printf fixture'})}]);
          };
          try {
            setup('permission');
            results.arrivalNeverApproves = replies().length === 0;
            key('permission', 'Enter', true);
            key('permission', 'Enter');
            results.unfocusedReturnNeverApproves = replies().length === 0;
            key('permission', '1', true);
            results.numberFocusDoesNotApprove = replies().length === 0 && document.activeElement.textContent === 'Approve once';
            key('permission', 'Enter'); key('permission', 'Enter');
            results.allowExactlyOnce = replies().length === 1 && replies()[0].action === 'allow';
            const pendingTerminal = document.querySelector('[data-request-terminal]');
            pendingTerminal.click();
            results.pendingTerminalStaysAvailable = !pendingTerminal.disabled && replies().length === 1 && messages.some(m => m.type === 'showTerminal');
            setup('next');
            results.oldIDCannotAnswerNext = !key('permission', 'Escape', true) && replies().length === 0;
            key('next', 'Escape', true); key('next', 'Escape', true);
            results.escapeDeniesOnce = replies().length === 1 && replies()[0].action === 'deny';
            const questions = [
              {question:'Pick views',multiSelect:true,options:[{label:'Reader'},{label:'Terminal'}]},
              {question:'Pick style',multiSelect:false,options:[{label:'Light'},{label:'Dark'}]}
            ];
            setup('question', questions);
            key('question', '1', true); key('question', '2');
            let cards = document.querySelectorAll('.reader-question');
            results.multiselectNumbers = [...cards[0].querySelectorAll('input[type=checkbox]')].every(c => c.checked) && replies().length === 0;
            key('question', 'Tab'); key('question', '2');
            results.tabNextQuestion = cards[1].contains(document.activeElement) && cards[1].querySelectorAll('input[type=radio]')[1].checked;
            key('question', 'Enter');
            results.choiceReturnDoesNotSubmit = replies().length === 0;
            const other = cards[1].querySelector('.reader-other'); other.focus(); other.value = '123';
            results.otherKeepsTyping = !key('question', '1') && !key('question', 'Enter') && other.value === '123' && replies().length === 0;
            const repeatedDigit = new KeyboardEvent('keydown', {key:'1',repeat:true,bubbles:true,cancelable:true});
            other.dispatchEvent(repeatedDigit);
            results.otherRepeatKeepsTyping = !repeatedDigit.defaultPrevented;
            other.dispatchEvent(new Event('input'));
            [...document.querySelectorAll('.reader-request button')].find(b => b.textContent === 'Submit answer').focus();
            key('question', 'Enter'); key('question', 'Enter');
            results.explicitSubmitOnce = replies().length === 1 && replies()[0].answers['Pick views'] === 'Reader, Terminal' && replies()[0].answers['Pick style'] === '123';
            setup('scope');
            const outside = document.createElement('input'); document.body.appendChild(outside); outside.focus();
            results.outsideScopeIgnored = !key('scope', 'Escape') && replies().length === 0;
            outside.remove();
            key('scope', 'ArrowDown', true);
            const repeated = new KeyboardEvent('keydown', {key:'Enter',repeat:true,bubbles:true,cancelable:true});
            document.activeElement.dispatchEvent(repeated);
            results.repeatedReturnIgnored = replies().length === 0 && repeated.defaultPrevented;
            key('scope', 'ArrowDown');
            results.arrowMovesFocus = document.activeElement.textContent === 'Deny';
            ReaderParity.openFind();
            results.findTakesPriority = !key('scope', 'Escape', true) && replies().length === 0;
            ReaderParity.closeFind();
            results.terminalAlwaysAvailable = [...document.querySelectorAll('.reader-request button')].some(b => b.textContent === 'Show Terminal');
            return results;
          } finally { ReaderParity.setRequests([]); hantuuRender.post = originalPost; }
        })()
        """#
        guard let results = js(page, script) as? [String: Bool], results.count == 18 else {
            check("request keyboard: fixture completed", false); return
        }
        for name in results.keys.sorted() { check("request keyboard: \(name)", results[name] == true) }
    }
}

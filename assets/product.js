// Interactions are scoped to the post-demo story; the existing tour is independent.
const story = document.querySelector('.afterword');
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const tabs = [...story.querySelectorAll('[data-study]')];
function selectStudy(tab, focus = false) {
  tabs.forEach(item => {
    const selected = item === tab;
    item.setAttribute('aria-selected', String(selected));
    item.tabIndex = selected ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !selected;
  });
  if (focus) tab.focus();
}
tabs.forEach((tab, index) => {
  tab.addEventListener('click', () => selectStudy(tab));
  tab.addEventListener('keydown', event => {
    const next = { ArrowRight: (index + 1) % tabs.length, ArrowLeft: (index + tabs.length - 1) % tabs.length, Home: 0, End: tabs.length - 1 }[event.key];
    if (next !== undefined) { event.preventDefault(); selectStudy(tabs[next], true); }
  });
});
const flip = story.querySelector('.aw-flip-card');
flip.addEventListener('click', () => {
  const expanded = flip.getAttribute('aria-expanded') !== 'true';
  flip.setAttribute('aria-expanded', String(expanded));
  flip.setAttribute('aria-label', expanded ? 'Show flashcard question' : 'Reveal flashcard answer');
  flip.querySelector('.aw-card-front').setAttribute('aria-hidden', String(expanded));
  flip.querySelector('.aw-card-back').setAttribute('aria-hidden', String(!expanded));
});
const answers = [...story.querySelectorAll('.aw-quiz-options button')];
const feedback = story.querySelector('.aw-quiz-feedback');
const reset = story.querySelector('.aw-quiz-reset');
answers.forEach(button => button.addEventListener('click', () => {
  answers.forEach(answer => answer.classList.remove('is-correct', 'is-wrong'));
  const correct = button.dataset.correct === 'true';
  button.classList.add(correct ? 'is-correct' : 'is-wrong');
  feedback.textContent = correct ? 'Exactly. Spacing out retrieval gives you repeated practice finding an idea again.' : 'Not quite. Try the habit that combines recalling an idea with time between sessions.';
  reset.hidden = false;
}));
reset.addEventListener('click', () => {
  answers.forEach(answer => answer.classList.remove('is-correct', 'is-wrong'));
  feedback.textContent = 'Choose an answer to check your understanding.';
  reset.hidden = true;
  answers[0].focus();
});
const courseNames = {
  psychology: 'Psychology 201 — How memories become lasting',
  philosophy: 'Philosophy 110 — What makes a good argument?',
  shiur: 'Morning shiur — Sources, discussion & notes'
};
const folders = [...story.querySelectorAll('[data-course]')];
folders.forEach(folder => folder.addEventListener('click', () => {
  story.querySelector('.aw-folders').classList.add('has-selection');
  folders.forEach(item => {
    item.classList.toggle('is-selected', item.dataset.course === folder.dataset.course);
    item.setAttribute('aria-pressed', String(item.dataset.course === folder.dataset.course));
  });
  story.querySelector('.aw-folder-selection').textContent = courseNames[folder.dataset.course];
}));
const motionButton = story.querySelector('.aw-motion-toggle');
motionButton.addEventListener('click', () => {
  const paused = story.classList.toggle('aw-motion-paused');
  motionButton.setAttribute('aria-pressed', String(paused));
  motionButton.innerHTML = `${paused ? 'Play animation' : 'Pause animation'} <span aria-hidden="true">${paused ? '▷' : 'Ⅱ'}</span>`;
});
if ('IntersectionObserver' in window) {
  const observer = new IntersectionObserver(entries => {
    entries.forEach(entry => {
      if (!entry.isIntersecting) return;
      entry.target.classList.remove('aw-reveal-pending');
      entry.target.classList.add('aw-entered');
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.08 });
  story.querySelectorAll('[data-aw-reveal]').forEach(element => {
    if (!reducedMotion.matches) element.classList.add('aw-reveal-pending');
    observer.observe(element);
  });
  // Continuous decorative motion only runs while its section is on screen.
  const motionObserver = new IntersectionObserver(entries => entries.forEach(entry => {
    entry.target.querySelectorAll('.aw-flow-trace, .aw-wave path, .aw-orbits g').forEach(element => {
      element.style.animationPlayState = entry.isIntersecting ? 'running' : 'paused';
    });
  }));
  story.querySelectorAll('.aw-flow, .aw-privacy').forEach(element => motionObserver.observe(element));
}

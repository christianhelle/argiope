function initializeTheme() {
    const savedTheme = localStorage.getItem('theme');
    const systemTheme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
    const theme = savedTheme || systemTheme;
    document.documentElement.setAttribute('data-theme', theme);

    const toggle = document.querySelector('.theme-toggle');
    if (toggle) {
        toggle.textContent = theme === 'dark' ? '☀' : '☾';
        toggle.setAttribute('aria-label', theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
    }
}

function toggleTheme() {
    const current = document.documentElement.getAttribute('data-theme') || 'light';
    const next = current === 'dark' ? 'light' : 'dark';
    localStorage.setItem('theme', next);
    initializeTheme();
}

function setupThemeToggle() {
    const toggle = document.querySelector('.theme-toggle');
    if (toggle) {
        toggle.addEventListener('click', toggleTheme);
    }

    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
        if (!localStorage.getItem('theme')) {
            initializeTheme();
        }
    });
}

function setupMobileNav() {
    const hamburger = document.querySelector('.hamburger');
    const menu = document.querySelector('.nav-menu');
    if (!hamburger || !menu) {
        return;
    }

    hamburger.addEventListener('click', () => {
        menu.classList.toggle('active');
        hamburger.classList.toggle('active');
    });

    document.querySelectorAll('.nav-menu a').forEach((link) => {
        link.addEventListener('click', () => {
            menu.classList.remove('active');
            hamburger.classList.remove('active');
        });
    });
}

function setupCopyButtons() {
    document.querySelectorAll('.code-block, .install-code').forEach((block) => {
        const code = block.querySelector('code');
        if (!code) {
            return;
        }

        const button = document.createElement('button');
        button.className = 'copy-button';
        button.type = 'button';
        button.textContent = 'Copy';

        button.addEventListener('click', async () => {
            try {
                await navigator.clipboard.writeText(code.textContent.trim());
                button.textContent = 'Copied';
                button.classList.add('copied');
                window.setTimeout(() => {
                    button.textContent = 'Copy';
                    button.classList.remove('copied');
                }, 1200);
            } catch (_) {
                button.textContent = 'Failed';
                window.setTimeout(() => {
                    button.textContent = 'Copy';
                }, 1200);
            }
        });

        block.appendChild(button);
    });
}

function setupCurrentPageHighlight() {
    const currentPath = window.location.pathname.split('/').pop() || 'index.html';
    document.querySelectorAll('.nav-link[data-page]').forEach((link) => {
        if (link.dataset.page === currentPath) {
            link.classList.add('active');
        }
    });
}

function setupSectionHighlight() {
    const page = document.body.dataset.page;
    if (page !== 'home') {
        return;
    }

    const sections = document.querySelectorAll('section[id]');
    const links = document.querySelectorAll('.nav-link[href^="#"]');

    const update = () => {
        let current = '';
        sections.forEach((section) => {
            const rect = section.getBoundingClientRect();
            if (rect.top <= 120 && rect.bottom >= 120) {
                current = section.id;
            }
        });

        links.forEach((link) => {
            link.classList.toggle('active', link.getAttribute('href') === `#${current}`);
        });
    };

    update();
    window.addEventListener('scroll', update, { passive: true });
}

function setupToc() {
    const toc = document.querySelector('.toc');
    const toggle = document.querySelector('.toc-toggle');
    if (!toc || !toggle) {
        return;
    }

    const overlay = document.createElement('div');
    overlay.className = 'sidebar-overlay';
    document.body.appendChild(overlay);

    const close = () => {
        toc.classList.remove('active');
        overlay.classList.remove('active');
    };

    toggle.addEventListener('click', () => {
        toc.classList.toggle('active');
        overlay.classList.toggle('active');
    });

    overlay.addEventListener('click', close);
    toc.querySelectorAll('a').forEach((link) => {
        link.addEventListener('click', close);
    });

    const sections = document.querySelectorAll('.doc-section[id]');
    const links = toc.querySelectorAll('a');
    const update = () => {
        let active = sections[0]?.id || '';
        sections.forEach((section) => {
            const rect = section.getBoundingClientRect();
            if (rect.top <= 150) {
                active = section.id;
            }
        });
        links.forEach((link) => {
            link.classList.toggle('active', link.getAttribute('href') === `#${active}`);
        });
    };

    update();
    window.addEventListener('scroll', update, { passive: true });
}

document.addEventListener('DOMContentLoaded', () => {
    initializeTheme();
    setupThemeToggle();
    setupMobileNav();
    setupCopyButtons();
    setupCurrentPageHighlight();
    setupSectionHighlight();
    setupToc();
});

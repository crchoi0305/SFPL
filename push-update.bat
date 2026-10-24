@echo off
cd /d "%~dp0"
git config --global user.name "Chungryong Choi"
git config --global user.email "crchoi@knu.ac.kr"
git add people/PI.html achievement/patent.html
git commit -m "Update PI contact info and patent list"
git push
pause
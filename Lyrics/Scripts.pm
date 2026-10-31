package Plugins::MusicArtistInfo::Lyrics::Scripts;

use strict;
use utf8;
use warnings;

sub default_search_script {
	return <<'SCRIPT';
# 移除字符（标题和艺术家都处理）
# $title  =~ s/[':.,!@#$%^&\[\]<>~;！（）【】；，。《》]//g;
# $artist =~ s/[':.,!@#$%^&\[\]<>~;！（）【】；，。《》]//g;
#
# 正则匹配移除字符（括号及内容）
# $title  =~ s/\s?\(.*\)//g;
# $artist =~ s/\s?\(.*\)//g;
#
# 正则匹配移除字符串（feat. 及之后）
# $title  =~ s/\s?feat.*//ig;
# $artist =~ s/\s?feat.*//ig;
#
# 自动搜索过滤示例（满足条件时跳过自动搜索）
# $skip = 1 if $title =~ /伴奏|off vocal|instrumental/i;
# $skip = 1 if $url =~ /伴奏|off vocal/i;

# 脚本结束时会自动返回 title / artist / skip
SCRIPT
}

sub default_processing_script {
	return <<'SCRIPT';
# 转换为繁体
# $lyrics = Plugins::MusicArtistInfo::Lyrics::HanConvert->convert($lyrics, 'traditional');
#
# 转换为简体
# $lyrics = Plugins::MusicArtistInfo::Lyrics::HanConvert->convert($lyrics, 'simplified');
#
# 移除全部空白行
# $lyrics =~ s/^\s*\n//mg;
#
# 压缩连续空白行
# $lyrics =~ s/\n{3,}/\n\n/g;
#
# 通配符移除
# $lyrics =~ s/\Q[00:00.00]\E//g;
#
# 替换
# $lyrics =~ s/old/new/g;
#
# 转换为标准格式（统一换行和行尾空白）
# $lyrics =~ s/\r\n?/\n/g;
# $lyrics =~ s/[ \t]+$//mg;
#
# 移除行首空白字符
# $lyrics =~ s/^[ \t]+//mg;

# 脚本结束时会自动返回 lyrics
SCRIPT
}

1;
